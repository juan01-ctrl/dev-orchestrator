import { createHash } from "node:crypto";
import { dirname } from "node:path";
import { Journal } from "./journal.ts";
import { API, APIError } from "./api.ts";
import { CodexSession, RepeatedFailureError, CodexBlockedError } from "./codex.ts";
import { RepositoryWorkspace } from "./repository.ts";
import { Publisher, type PublicationContext } from "./publisher.ts";
import type { Config, JournalState } from "./types.ts";

type Transport={post:(path:string,payload:unknown)=>Promise<any>};
type ExecutionDependencies={dataRoot?:string;repositories?:RepositoryWorkspace;publisherFactory?:(context:PublicationContext)=>Publisher};

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

export async function recover(api:Transport,journal:Journal,repositories?:RepositoryWorkspace,dataRoot?:string):Promise<void> {
  const state=await journal.load();
  if(!state)return;
  const result=await api.post("/executor/reconcile",{lease:state.lease,journal:{pending_event:state.pending_event??null}});
  let terminalState=result.state;
  if(result.action==="replay" && state.pending_event) {
    const kind=state.pending_event.kind;
    const acknowledgement=await api.post("/executor/events",{lease:state.lease,event:state.pending_event});
    if(["succeeded","blocked","failed","cancelled"].includes(acknowledgement?.state))terminalState=acknowledgement.state;
    if(["started","progress"].includes(kind))terminalState=(await api.post("/executor/reconcile",{lease:state.lease,journal:{pending_event:null}})).state;
  } else if(result.action!=="acknowledge")throw new Error("Task reconciliation needs operator attention.");
  if(state.workspace && repositories && dataRoot && ["succeeded","blocked","failed","cancelled"].includes(terminalState)) {
    await repositories.markTerminal(state.workspace,terminalState==="succeeded"?"success":"failure");
  }
  await journal.clear();
}

export async function runLoop(config:Config,root:string,signal:AbortSignal):Promise<void> {
  const api=new API(config.server,config.token);
  const journal=new Journal(root);
  const repositories=new RepositoryWorkspace();
  await recover(api,journal,repositories,dirname(root));
  const health=CodexSession.start(config.codexBinary??"codex",root);
  let authenticated=false;
  try {await health.initialize();authenticated=await health.authenticated();}finally{health.stop();}
  await api.post("/executor/heartbeat",{protocol:1,codex_authenticated:authenticated,platform:process.platform});
  if(!authenticated)throw new Error("Sign in to the official Codex CLI with your own ChatGPT account before starting this connector.");
  while(!signal.aborted) {
    try {
      await recover(api,journal,repositories,dirname(root));
      await api.post("/executor/heartbeat",{protocol:1,codex_authenticated:true,platform:process.platform});
      const claimStarted=performance.now();
      const lease=await api.post("/executor/claim",{});
      if(lease)await execute(config,api,journal,{lease,sequence:lease.sequence??0},claimStarted,signal,{dataRoot:dirname(root)});
    } catch(error) {
      if(signal.aborted)break;
      if(error instanceof APIError && error.status===401)throw new Error("Executor access was revoked. Pair again with an authorized owner.");
      console.error("Control-plane operation interrupted. Preserved task state; reconnecting without rerunning unacknowledged work.");
    }
    await new Promise(resolve=>setTimeout(resolve,5_000));
  }
}

export async function execute(config:Config,api:Transport,journal:Journal,state:JournalState,claimStarted:number,signal:AbortSignal,dependencies:ExecutionDependencies={}):Promise<void> {
  const controller=new AbortController();
  let session:CodexSession|undefined;
  let phase="github_installation_required";
  let deadline=claimStarted+Math.min(state.lease.expires_in_ms??90_000,90_000)-5_000;
  const abort=()=>{controller.abort();session?.stop();};
  let workspacePath:string|undefined;
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
    await emitDurably(api,journal,state,"started",{});
    await emitDurably(api,journal,state,"progress",{stage:"repository_preparing"});
    const dataRoot=dependencies.dataRoot??dirname(journal.root);
    const repositories=dependencies.repositories??new RepositoryWorkspace();
    await repositories.cleanupExpired(dataRoot);
    const credential=await api.post("/executor/github-token",{lease:state.lease,purpose:"checkout"});
    phase="workspace_setup_failed";
    const workspace=await repositories.prepare(dataRoot,state.lease,credential);
    workspacePath=workspace.path;
    const snapshot=state.lease.snapshot??{};
    const instructionsPath=await repositories.writeProjectInstructions(workspace.path,snapshot.instructions??"");
    state.workspace=workspace.path;state.baseline=workspace.baseline;await journal.save(state);
    if(controller.signal.aborted)throw new Error("Lease ended.");
    await emitDurably(api,journal,state,"progress",{stage:"workspace_ready"});
    phase="authentication_required";
    session=CodexSession.start(config.codexBinary??"codex",workspace.path);
    await session.initialize();
    if(!await session.authenticated())throw new Error("Local account is not signed in.");
    phase="execution_failed";
    const prompt=[
      "Implement this development task end to end in this isolated checkout.",
      "Read and respect the repository's AGENTS.md and project-scoped skills. Do not change global skills or configuration.",
      "Validate changes and create a Conventional Commit on the existing issue branch. Do not push, create a PR, merge, or deploy: the trusted connector handles publication after your turn.",
      "Do not invent external access or credentials. If essential context is missing, report a real blocker. Network access is disabled in this evaluation sandbox.",
      instructionsPath
        ? "Project instructions: read and follow the file at "+instructionsPath+" before making changes."
        : "Project instructions:\n"+String(snapshot.instructions??""),
      "Task: "+String(state.lease.title??""),String(state.lease.prompt??"")
    ].join("\n\n");
    let activityWrites = Promise.resolve();
    const writeEvent = (kind:string,data:Record<string,unknown>) => {
      activityWrites = activityWrites.then(() => emitDurably(api,journal,state,kind,data));
      return activityWrites;
    };
    await session.run(
      workspace.path,
      prompt,
      typeof snapshot.model==="string"?snapshot.model:undefined,
      controller.signal,
      stage=>writeEvent("progress",{stage}),
      event=>writeEvent("activity",{event})
    );
    await activityWrites;
    session.stop();session=undefined;
    phase="publication_failed";
    await api.post("/executor/renew",state.lease);
    const publicationContext={workspace:workspace.path,repository:String(snapshot.repository??""),baseBranch:String(snapshot.base_branch??""),branch:workspace.branch,baseline:workspace.baseline};
    const publisher=dependencies.publisherFactory?.(publicationContext)??new Publisher(publicationContext);
    const status=await publisher.status(controller.signal);
    if(status.changed) {
      await emitDurably(api,journal,state,"progress",{stage:"publishing"});
      const publishCredential=await api.post("/executor/github-token",{lease:state.lease,purpose:"publish"});
      const result=await publisher.publish(state.lease.title??"Development task",`## Summary\n\nCompleted by the customer-owned local executor.\n\n## Validation\n\nReview the committed changes and repository checks before merging.\n\nRun: ${state.lease.id}`,publishCredential,controller.signal);
      if(controller.signal.aborted)throw new Error("Lease ended.");
      await emitDurably(api,journal,state,"progress",{stage:"pr_verifying"});
      const acknowledgement=await emitDurably(api,journal,state,"candidate",result);
      if(acknowledgement?.state==="succeeded")await repositories.markTerminal(workspace.path,"success").catch(()=>{});
    } else {
      const acknowledgement=await emitDurably(api,journal,state,"no_changes",{});
      if(acknowledgement?.state==="succeeded")await repositories.markTerminal(workspace.path,"success").catch(()=>{});
    }
    await journal.clear();
  } catch(error) {
    session?.stop();
    if(controller.signal.aborted || state.pending_event)throw error;
    if(error instanceof APIError && ["github_installation_required","github_permission_denied","base_branch_missing","github_unavailable","local_policy_denied"].includes(error.code))phase=error.code;
    else if(error instanceof APIError && error.code==="provider_authentication")phase="github_permission_denied";
    else if(error instanceof APIError && ["provider_rejected","provider_rate_limit","provider_unavailable"].includes(error.code))phase="github_unavailable";
    else if(error instanceof Error && /Selected base branch does not resolve to a commit/i.test(error.message))phase="base_branch_missing";
    else if(error instanceof Error && /Repository setup failed|worktree|managed repository cache|Task repository snapshot/i.test(error.message))phase="workspace_setup_failed";
    if(error instanceof CodexBlockedError)phase="missing_context";
    const fingerprint=error instanceof RepeatedFailureError?error.fingerprint:createHash("sha256").update(phase+":"+(error instanceof Error?error.message:"unknown")).digest("hex");
    const kind=["authentication_required","local_policy_denied","github_installation_required","github_permission_denied","base_branch_missing","missing_context","workspace_setup_failed"].includes(phase)?"blocked":"failure";
    const acknowledgement=await emitDurably(api,journal,state,kind,{category:phase,fingerprint,occurrences:error instanceof RepeatedFailureError?3:1});
    if(workspacePath && ["blocked","cancelled","failed"].includes(acknowledgement?.state)) {
      await (dependencies.repositories??new RepositoryWorkspace()).markTerminal(workspacePath,"failure").catch(()=>{});
    }
    await journal.clear();
  } finally {
    clearInterval(safety);clearInterval(renewal);clearTimeout(timeBudget);
    signal.removeEventListener("abort",abort);session?.stop();
  }
}
