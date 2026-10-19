import { hostname } from "node:os";
import { dirname, join, resolve } from "node:path";
import { realpath, mkdir, open, unlink } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { API } from "./api.ts";
import { loadConfig, saveConfig, serverURL } from "./config.ts";
import { validateMapping } from "./workspace.ts";
import { CodexSession } from "./codex.ts";
import { runLoop } from "./worker.ts";

export async function main(args:string[]):Promise<void> {
  const [action,...rest]=args;
  if(!action || action==="help" || action==="--help") {
    console.log("Dev Orchestrator connector\n\npair --server URL --code CODE --config /absolute/config.json\nallow --config FILE --project ID --repo owner/repo --source /absolute/repo --workspaces /absolute/isolated-root [--base main]\nstatus --config FILE\nrun --config FILE\n\nThis connector uses your official local Codex login. It never modifies Symphony or global provider/Git configuration.");return;
  }
  const opts:Record<string,string>={};
  for(let i=0;i<rest.length;i+=2){if(!/^--[a-z-]+$/.test(rest[i]) || !rest[i+1])throw new Error("Options require --name value pairs.");opts[rest[i].slice(2)]=rest[i+1];}
  if(!opts.config || !opts.config.startsWith("/"))throw new Error("Provide an absolute --config path.");
  const file=opts.config;
  if(action==="pair") {
    // Do not consume a one-use code if a pairing already exists.
    const reservation=await open(file+".pairing","wx",0o600).catch(()=>{throw new Error("Configuration directory must exist and no pairing may already be in progress.");});
    try {
      try {await loadConfig(file);throw new Error("This configuration is already paired.");}
      catch(error){if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;}
      const server=serverURL(opts.server);
      const result=await new API(server).post("/enroll",{code:opts.code,name:opts.name??hostname()});
      if(typeof result.token!=="string")throw new Error("Invalid enrollment response.");
      await saveConfig(file,{version:1,server,token:result.token,mappings:[]},true);
      console.log("Paired. Ask the owner to bind a project, then authorize its repository locally with allow.");
    } finally {await reservation.close();await unlink(file+".pairing");}
    return;
  }
  const config=await loadConfig(file);
  if(action==="allow") {
    if(!opts.workspaces || !opts.source || !opts.project || !opts.repo)throw new Error("Provide --project, --repo, --source and --workspaces.");
    await mkdir(resolve(opts.workspaces),{recursive:true,mode:0o700});
    const mapping=await validateMapping({projectId:opts.project,repository:opts.repo,baseBranch:opts.base??"main",source:await realpath(resolve(opts.source)),workspaceRoot:await realpath(resolve(opts.workspaces))});
    config.mappings=config.mappings.filter(m=>m.projectId!==mapping.projectId).concat(mapping);
    await saveConfig(file,config);
    console.log("Project authorized locally. Only this repository, base branch and workspace root can be used.");return;
  }
  if(action==="status") {
    const session=CodexSession.start(config.codexBinary??"codex",dirname(file));
    try {await session.initialize();console.log(JSON.stringify({codex_authenticated:await session.authenticated(),authorized_projects:config.mappings.length}));}
    finally{session.stop();}return;
  }
  if(action!=="run")throw new Error("Unknown command. Use help.");
  const root=join(dirname(file),"runtime");await mkdir(root,{recursive:true,mode:0o700});
  const lock=join(root,"connector.lock");
  const fd=await open(lock,"wx",0o600).catch(()=>{throw new Error("Connector lock exists. Confirm no connector is running before removing that exact lock file.");});
  await fd.writeFile(String(process.pid));
  const controller=new AbortController();
  const stop=()=>controller.abort();process.once("SIGINT",stop);process.once("SIGTERM",stop);
  try {console.log("Connector running. Press Ctrl+C to stop; interrupted work is preserved.");await runLoop(config,root,controller.signal);}
  finally {controller.abort();process.off("SIGINT",stop);process.off("SIGTERM",stop);await fd.close();await unlink(lock);}
}

if(process.argv[1] && import.meta.url===pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(error=>{console.error(error instanceof Error?error.message:"Connector operation failed.");process.exitCode=1;});
}
