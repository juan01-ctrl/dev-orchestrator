import { spawn, type ChildProcess } from "node:child_process";

export const cleanGitEnv = (): NodeJS.ProcessEnv => ({
  PATH: process.env.PATH, HOME: process.env.HOME,
  LANG: "C", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
  GIT_TERMINAL_PROMPT: "0", GIT_NO_REPLACE_OBJECTS: "1"
});

export async function readAuthor(source:string,env:NodeJS.ProcessEnv={PATH:process.env.PATH,HOME:process.env.HOME,XDG_CONFIG_HOME:process.env.XDG_CONFIG_HOME,GIT_CONFIG_NOSYSTEM:"1"}):Promise<{name:string;email:string}> {
  // Reading these two values does not execute hooks or credential helpers.
  const name=(await command("git",["-C",source,"config","--get","user.name"],{env})).output;
  const email=(await command("git",["-C",source,"config","--get","user.email"],{env})).output;
  if(!name || name.length>200 || !email || email.length>254 || /[\r\n]/.test(name+email))throw new Error("Configure a Git author on the customer host before running tasks.");
  return {name,email};
}

export function stopProcess(child: ChildProcess): void {
  if (!child.pid || child.exitCode !== null) return;
  try { process.kill(-child.pid,"SIGKILL"); } catch { child.kill("SIGKILL"); }
}

export async function command(binary: string, args: string[], opts: { cwd?: string; env?: NodeJS.ProcessEnv; signal?: AbortSignal; timeout?: number; allowExitOne?: boolean } = {}): Promise<{ output: string; code: number }> {
  return new Promise((resolve,reject)=>{
    const child=spawn(binary,args,{cwd:opts.cwd,env:opts.env ?? cleanGitEnv(),detached:true,stdio:["ignore","pipe","ignore"]});
    let output="",settled=false;
    const fail=()=>{if(!settled){settled=true;stopProcess(child);reject(new Error("Local command failed."));}};
    const timer=setTimeout(fail,opts.timeout ?? 30_000);
    const abort=()=>fail();
    opts.signal?.addEventListener("abort",abort,{once:true});
    if(opts.signal?.aborted) fail();
    child.stdout.on("data",chunk=>{output+=chunk.toString();if(output.length>1_048_576)fail();});
    child.on("error",fail);
    child.on("close",code=>{
      clearTimeout(timer);opts.signal?.removeEventListener("abort",abort);
      if(settled)return;settled=true;
      if(code===0 || (code===1 && opts.allowExitOne))resolve({output:output.trim(),code:code!});
      else reject(new Error("Local command failed."));
    });
  });
}
