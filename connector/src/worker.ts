import { createHash } from "node:crypto";
import { Journal } from "./journal.ts";
import { API, APIError } from "./api.ts";
import { CodexSession, RepeatedFailureError, CodexBlockedError } from "./codex.ts";
import { prepareWorkspace } from "./workspace.ts";
import { Publisher } from "./publisher.ts";
import type { Config, JournalState } from "./types.ts";

type Transport={post:(path:string,payload:unknown)=>Promise<any>};

export async function emitDurably(api:Transport,journal:Journal,state:JournalState,kind:string,data:Record<string,unknown>):Promise<any> {
  if(state.pending_event)throw new Error("A previous event still needs acknowledgement.");
  state.sequence++;
  state.pending_event={sequence:state.sequence,kind,data};
  await journal.save(state);
  const result=await api.post("/executor/events",{lease:state.lease,event:state.pending_event});
  delete state.pending_event;
  await journal.save(state);
  return result;
}

export async function recover(api:Transport,journal:Journal):Promise<void> {
  const state=await journal.load();
  if(!state)return;
  const result=await api.post("/executor/reconcile",{lease:state.lease,journal:{pending_event:state.pending_event??null}});
  if(result.action==="replay" && state.pending_event) {
    const kind=state.pending_event.kind;
    await api.post("/executor/events",{lease:state.lease,event:state.pending_event});
    if(["started","progress"].includes(kind))await api.post("/executor/reconcile",{lease:state.lease,journal:{pending_event:null}});
  } else if(result.action!=="acknowledge")throw new Error("Task reconciliation needs operator attention.");
  await journal.clear();
}

export async function runLoop(config:Config,root:string,signal:AbortSignal):Promise<void> {
  const api=new API(config.server,config.token);
  const journal=new Journal(root);
  await recover(api,journal);
  const health=CodexSession.start(config.codexBinary??"codex",root);
  let authenticated=false;
  try {await health.initialize();authenticated=await health.authenticated();}finally{health.stop();}
  await api.post("/executor/heartbeat",{protocol:1,codex_authenticated:authenticated,platform:process.platform});
  if(!authenticated)throw new Error("Sign in to the official Codex CLI with your own ChatGPT account before starting this connector.");
  while(!signal.aborted) {
    try {
      await recover(api,journal);
      await api.post("/executor/heartbeat",{protocol:1,codex_authenticated:true,platform:process.platform});
      const claimStarted=performance.now();
      const lease=await api.post("/executor/claim",{});
      if(lease)await execute(config,api,journal,{lease,sequence:lease.sequence??0},claimStarted,signal);
    } catch(error) {
      if(signal.aborted)break;
      if(error instanceof APIError && error.status===401)throw new Error("Executor access was revoked. Pair again with an authorized owner.");
      console.error("Control-plane operation interrupted. Preserved task state; reconnecting without rerunning unacknowledged work.");
    }
    await new Promise(resolve=>setTimeout(resolve,5_000));
  }
}

async function execute(config:Config,api:Transport,journal:Journal,state:JournalState,claimStarted:number,signal:AbortSignal):Promise<void> {
  const controller=new AbortController();
  let session:CodexSession|undefined;
  let phase="local_policy_denied";
  let deadline=claimStarted+Math.min(state.lease.expires_in_ms??90_000,90_000)-5_000;
  const abort=()=>{controller.abort();session?.stop();};
  signal.addEventListener("abort",abort,{once:true});
  const safety=setInterval(()=>{if(performance.now()>=deadline)abort();},250);
  const renewal=setInterval(async()=>{
    const started=performance.now();
    try {
      const result=await api.post("/executor/renew",state.lease);
      if(!controller.signal.aborted)deadline=started+Math.min(result.expires_in_ms,90_000)-5_000;
    } catch(error) {
      if(error instanceof APIError && [401,409].includes(error.status))abort();
      // A transport failure does not extend the last acknowledged deadline.
    }
  },20_000);
  const timeBudget=setTimeout(abort,20*60_000);
  try {
    await journal.save(state);
    const mapping=config.mappings.find(m=>m.projectId===state.lease.project_id);
    if(!mapping)throw new Error("Project not authorized locally.");
    const workspace=await prepareWorkspace(mapping,state.lease);
    state.workspace=workspace.path;state.baseline=workspace.baseline;await journal.save(state);
    if(controller.signal.aborted)throw new Error("Lease ended.");
    await emitDurably(api,journal,state,"started",{});
    phase="authentication_required";
    session=CodexSession.start(config.codexBinary??"codex",workspace.path);
    await session.initialize();
    if(!await session.authenticated())throw new Error("Local account is not signed in.");
    phase="execution_failed";
    const snapshot=state.lease.snapshot??{};
    const prompt=[
      "Implement this development task end to end in this isolated checkout.",
      "Read and respect the repository's AGENTS.md and project-scoped skills. Do not change global skills or configuration.",
      "Validate changes and create a Conventional Commit on the existing issue branch. Do not push, create a PR, merge, or deploy: the trusted connector handles publication after your turn.",
      "Do not invent external access or credentials. If essential context is missing, report a real blocker. Network access is disabled in this evaluation sandbox.",
      "Project instructions:\n"+String(snapshot.instructions??""),
      "Task: "+String(state.lease.title??""),String(state.lease.prompt??"")
    ].join("\n\n");
    await session.run(workspace.path,prompt,typeof snapshot.model==="string"?snapshot.model:undefined,controller.signal);
    session.stop();session=undefined;
    phase="publication_failed";
    await api.post("/executor/renew",state.lease);
    const publisher=new Publisher({workspace:workspace.path,repository:mapping.repository,baseBranch:mapping.baseBranch,branch:workspace.branch,baseline:workspace.baseline});
    const status=await publisher.status(controller.signal);
    if(status.changed) {
      const result=await publisher.publish(state.lease.title??"Development task",`## Summary\n\nCompleted by the customer-owned local executor.\n\n## Validation\n\nReview the committed changes and repository checks before merging.\n\nRun: ${state.lease.id}`,controller.signal);
      if(controller.signal.aborted)throw new Error("Lease ended.");
      await emitDurably(api,journal,state,"candidate",result);
    } else {
      await emitDurably(api,journal,state,"no_changes",{});
    }
    await journal.clear();
  } catch(error) {
    session?.stop();
    if(controller.signal.aborted || state.pending_event)throw error;
    if(error instanceof CodexBlockedError)phase="missing_context";
    const fingerprint=error instanceof RepeatedFailureError?error.fingerprint:createHash("sha256").update(phase+":"+(error instanceof Error?error.message:"unknown")).digest("hex");
    const kind=["authentication_required","local_policy_denied","missing_context"].includes(phase)?"blocked":"failure";
    await emitDurably(api,journal,state,kind,{category:phase,fingerprint,occurrences:error instanceof RepeatedFailureError?3:1});
    await journal.clear();
  } finally {
    clearInterval(safety);clearInterval(renewal);clearTimeout(timeBudget);
    signal.removeEventListener("abort",abort);session?.stop();
  }
}
