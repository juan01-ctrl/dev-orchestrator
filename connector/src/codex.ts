import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createHash } from "node:crypto";
import { stopProcess } from "./process.ts";
import { activityForNotification, type ActivityStage } from "./activity.ts";

type Pending={resolve:(value:any)=>void;reject:(reason:Error)=>void;timer:NodeJS.Timeout};

export class RepeatedFailureError extends Error {
  readonly fingerprint: string;
  constructor(fingerprint:string){super("Codex repeated the same failed command three times.");this.fingerprint=fingerprint;}
}
export class CodexBlockedError extends Error {}

export class CodexSession {
  readonly child: ChildProcessWithoutNullStreams;
  readonly events=new EventEmitter();
  private pending=new Map<number,Pending>();
  private id=0;
  private buffer="";
  private failed:Error|null=null;
  private commandFailures=new Map<string,number>();

  constructor(child:ChildProcessWithoutNullStreams) {
    this.child=child;
    child.stderr.resume();
    child.stdin.on("error",()=>this.fail(new Error("Codex transport closed.")));
    child.stdout.on("data",chunk=>this.consume(chunk.toString()));
    child.on("error",()=>this.fail(new Error("Codex could not start. Check the locally installed CLI.")));
    child.on("close",()=>this.fail(new Error("Codex process stopped before completion.")));
  }

  static start(binary:string,workspace:string):CodexSession {
    // Keep provider-owned local login, but never forward API/Git tokens into the agent.
    const allowed=["PATH","HOME","USER","LOGNAME","SHELL","TMPDIR","LANG","LC_ALL","CODEX_HOME","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY"];
    const env=Object.fromEntries(allowed.filter(key=>process.env[key]!==undefined).map(key=>[key,process.env[key]]));
    const args=["app-server","--listen","stdio://",
      "-c",'permissions.dev-orchestrator.extends=":workspace"',
      "-c",'permissions.dev-orchestrator.filesystem={":workspace_roots"={"."="write",".git"="write",".agents"="write",".codex"="read",".aws"="read"}}',
      "-c","permissions.dev-orchestrator.network.enabled=false"];
    return new CodexSession(spawn(binary,args,{cwd:workspace,env,detached:true,stdio:["pipe","pipe","pipe"]}));
  }

  async initialize():Promise<void> {
    await this.request("initialize",{clientInfo:{name:"dev_orchestrator",title:"Dev Orchestrator",version:"0.1.0"},capabilities:{experimentalApi:true}});
    this.send({method:"initialized",params:{}});
  }
  async authenticated():Promise<boolean> {
    const result=await this.request("account/read",{refreshToken:false});
    return result.account?.type==="chatgpt";
  }

  async run(workspace:string,prompt:string,model:string|undefined,signal?:AbortSignal,onProgress?:(stage:ActivityStage)=>Promise<void>):Promise<void> {
    const thread=await this.request("thread/start",{cwd:workspace,approvalPolicy:"never",permissions:"dev-orchestrator",...(model?{model}:{})});
    const threadId=thread.thread?.id;
    if(!threadId)throw new Error("Codex returned no task thread.");
    let onNotification:(message:any)=>void;
    let onFailure:(error:Error)=>void;
    let abort:()=>void;
    let outcome:string|undefined;
    let lastStage:ActivityStage|undefined;
    let progressQueue=Promise.resolve();
    let progressFailure:Error|undefined;
    const completed=new Promise<void>((resolve,reject)=>{
      onNotification=(message)=>{
        if(message.params?.threadId===threadId) {
          const stage=activityForNotification(message);
          if(stage && stage!==lastStage) {
            lastStage=stage;
            progressQueue=progressQueue.then(()=>onProgress?.(stage));
            void progressQueue.catch(error=>{
              progressFailure=error instanceof Error?error:new Error("Progress delivery failed.");
              this.fail(progressFailure);
            });
          }
        }
        if(message.method==="item/completed" && message.params?.threadId===threadId && message.params.item?.type==="agentMessage") {
          try {const result=JSON.parse(message.params.item.text);if(["completed","blocked"].includes(result?.outcome))outcome=result.outcome;}catch{/* Wait for a valid structured final answer. */}
        }
        if(message.method==="turn/completed" && message.params?.threadId===threadId) {
          if(outcome==="blocked")reject(new CodexBlockedError("Essential context is missing; the task is blocked."));
          else if(message.params.turn?.status==="completed" && outcome==="completed")resolve();
          else reject(new Error("Codex turn did not complete."));
        }
      };
      onFailure=reject;
      abort=()=>{this.stop();reject(new Error("Task stopped before lease expiration."));};
      this.events.on("notification",onNotification);
      this.events.once("failure",onFailure);
      signal?.addEventListener("abort",abort,{once:true});
      if(signal?.aborted)abort();
    });
    // Attach a rejection handler before turn/start to cover an early process exit.
    completed.catch(()=>{});
    try {
      await this.request("turn/start",{threadId,cwd:workspace,approvalPolicy:"never",permissions:"dev-orchestrator",input:[{type:"text",text:prompt}],outputSchema:{type:"object",properties:{outcome:{type:"string",enum:["completed","blocked"]}},required:["outcome"],additionalProperties:false}});
      await completed;
      await progressQueue;
      if(progressFailure)throw progressFailure;
    } finally {
      this.events.off("notification",onNotification!);this.events.off("failure",onFailure!);
      signal?.removeEventListener("abort",abort!);
    }
  }

  stop():void {stopProcess(this.child);this.fail(new Error("Codex stopped."));}

  private request(method:string,params:unknown):Promise<any> {
    if(this.failed)return Promise.reject(this.failed);
    return new Promise((resolve,reject)=>{
      const id=++this.id;
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error("Codex request timed out."));this.stop();},30_000);
      this.pending.set(id,{resolve,reject,timer});this.send({id,method,params});
    });
  }
  private send(message:unknown):void {if(!this.child.stdin.destroyed)this.child.stdin.write(JSON.stringify(message)+"\n");}
  private consume(chunk:string):void {
    this.buffer+=chunk;
    if(this.buffer.length>1_048_576){this.fail(new Error("Codex message exceeded the size limit."));this.stop();return;}
    let newline:number;
    while((newline=this.buffer.indexOf("\n"))>=0) {
      const line=this.buffer.slice(0,newline);this.buffer=this.buffer.slice(newline+1);
      if(!line.trim())continue;
      let message:any;
      try{message=JSON.parse(line);}catch{this.fail(new Error("Invalid Codex protocol response."));this.stop();return;}
      if(!message || typeof message!=="object" || Array.isArray(message)){this.fail(new Error("Invalid Codex protocol response."));this.stop();return;}
      if(message.method==="item/completed") {
        const item=message.params?.item;
        if(item?.type==="commandExecution" && (typeof item.exitCode==="number" && item.exitCode!==0 || item.status==="failed")) {
          const command=String(item.command??"");
          const wrapped=command.trim().match(/^(?:\/[^\s]+\/)?(?:bash|zsh|sh)\s+-lc\s+(['"])([\s\S]*)\1$/);
          const probe=(wrapped?.[2]??command).trim();
          const unquoted=probe.replace(/"[^"\n]*"|'[^'\n]*'/g,"");
          const expectedMiss=item.exitCode===1 && /^(?:rg|grep|test|\[)(?:\s|$)/.test(probe) && !/[;&|]/.test(unquoted);
          if(!expectedMiss) {
            const detail=(command+":"+String(item.exitCode)+":"+String(item.aggregatedOutput??"")).replace(/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi,"<id>").replace(/\b\d+(?:\.\d+)?\s*(?:ms|s|seconds)\b/g,"<duration>");
            const fingerprint=createHash("sha256").update(detail).digest("hex");
            const count=(this.commandFailures.get(fingerprint)??0)+1;this.commandFailures.set(fingerprint,count);
            if(count>=3){this.fail(new RepeatedFailureError(fingerprint));this.stop();return;}
          }
        }
      }
      if(message.method && message.id!==undefined) {
        // The connector never auto-approves a broader permission or user-input request.
        this.send({id:message.id,error:{code:-32000,message:"Required context or permission is unavailable; task blocked."}});
        this.fail(new Error("Codex needs context or unsupported permissions."));this.stop();return;
      }
      if(message.id!==undefined) {
        const pending=this.pending.get(message.id);
        if(pending){clearTimeout(pending.timer);this.pending.delete(message.id);message.error?pending.reject(new Error("Codex rejected the configured request or sandbox.")):pending.resolve(message.result);}
      } else if(message.method)this.events.emit("notification",message);
    }
  }
  private fail(error:Error):void {
    if(this.failed)return;
    this.failed=error;
    for(const pending of this.pending.values()){clearTimeout(pending.timer);pending.reject(error);}this.pending.clear();
    this.events.emit("failure",error);
  }
}
