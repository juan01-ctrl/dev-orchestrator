import { spawn, type ChildProcess } from "node:child_process";

export type CommandFailureReason = "access_denied" | "network" | "missing_ref" | "filesystem" | "unknown";

export class CommandFailure extends Error {
  readonly reason:CommandFailureReason;
  constructor(reason:CommandFailureReason) {
    super("Local command failed.");
    this.reason=reason;
  }
}

function failureReason(stderr:string):CommandFailureReason {
  if(/CONNECT tunnel failed|could not resolve host|failed to connect|connection (?:timed out|refused)|network is unreachable|SSL connection|TLS handshake/i.test(stderr))return "network";
  if(/couldn'?t find remote ref|remote ref .* not found/i.test(stderr))return "missing_ref";
  if(/repository not found|authentication failed|invalid username or token|could not read Username|\bHTTP (?:401|403)\b|requested URL returned error: (?:401|403)|not authorized/i.test(stderr))return "access_denied";
  if(/no space left on device|read-only file system|operation not permitted|permission denied/i.test(stderr))return "filesystem";
  return "unknown";
}

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

export async function command(binary: string, args: string[], opts: { cwd?: string; env?: NodeJS.ProcessEnv; signal?: AbortSignal; timeout?: number; allowExitOne?: boolean; trimOutput?:boolean } = {}): Promise<{ output: string; code: number }> {
  return new Promise((resolve,reject)=>{
    const child=spawn(binary,args,{cwd:opts.cwd,env:opts.env ?? cleanGitEnv(),detached:true,stdio:["ignore","pipe","pipe"]});
    let output="",stderr="",settled=false;
    const fail=(reason:CommandFailureReason)=>{if(!settled){settled=true;stopProcess(child);reject(new CommandFailure(reason));}};
    const timer=setTimeout(()=>fail("network"),opts.timeout ?? 30_000);
    const abort=()=>fail("unknown");
    opts.signal?.addEventListener("abort",abort,{once:true});
    if(opts.signal?.aborted) fail("unknown");
    child.stdout.on("data",chunk=>{output+=chunk.toString();if(output.length>1_048_576)fail("unknown");});
    child.stderr.on("data",chunk=>{stderr=(stderr+chunk.toString()).slice(-16_384);});
    child.on("error",error=>fail((error as NodeJS.ErrnoException).code==="EACCES"?"filesystem":"unknown"));
    child.on("close",code=>{
      clearTimeout(timer);opts.signal?.removeEventListener("abort",abort);
      if(settled)return;settled=true;
      if(code===0 || (code===1 && opts.allowExitOne))resolve({output:opts.trimOutput===false?output:output.trim(),code:code!});
      else reject(new CommandFailure(failureReason(stderr)));
    });
  });
}
