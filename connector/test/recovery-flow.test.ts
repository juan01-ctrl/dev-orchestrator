import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, chmod, rm, realpath } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execute, recover } from "../src/worker.ts";
import { RepositoryWorkspace } from "../src/repository.ts";
import { Journal } from "../src/journal.ts";
import type { JournalState } from "../src/types.ts";
import { reviewIdentity } from "../src/reviewer.ts";

type Verdict="approve"|"request_changes"|"blocked"|"invalid";
async function fixture(mode: "repair" | "fail" | "text" | "setup_fail" | "reported_fail" | "reported_mixed" = "repair", failures: { publish?: number; verify?: number; checkoutDuringPublish?:boolean } = {}, reviewVerdict?: Verdict|Verdict[], question?:any) {
  const root = await realpath(await mkdtemp(join(tmpdir(), "orchestrator-flow-")));
  const source = join(root, "source"), remote = join(root, "remote.git");
  await mkdir(source);
  const git = (args: string[]) => execFileSync("git", ["-C", source, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  git(["init", "-b", "main"]); git(["config", "user.name", "Test"]); git(["config", "user.email", "test@example.test"]);
  await writeFile(join(source, "package.json"), JSON.stringify({ scripts: mode==="reported_fail"?{}:{ check: "node app.js" } }));
  await writeFile(join(source, "app.js"), "initial"); git(["add", "."]); git(["commit", "-m", "test: baseline"]);
  execFileSync("git", ["init", "--bare", remote], { stdio: "ignore" }); git(["push", remote, "main"]);
  const observation = join(root, "observations.jsonl"), binary = join(root, "fake-codex.mjs");
  await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline'; import {writeFileSync,appendFileSync,mkdirSync,readFileSync} from 'node:fs';
const send=o=>process.stdout.write(JSON.stringify(o)+'\\n');let turn=0;
readline.createInterface({input:process.stdin}).on('line',line=>{
 const m=JSON.parse(line);if(m.id===undefined)return;
 if(m.id==='decision-request'){
  appendFileSync(${JSON.stringify(observation)},JSON.stringify({method:'decision-answer',params:m.result})+'\\n');
  send({method:'item/completed',params:{threadId:'persistent-task-thread',item:{type:'agentMessage',text:JSON.stringify({outcome:'completed',summary:'Continued autonomously',validation:[],blocker:null})}}});
  return send({method:'turn/completed',params:{threadId:'persistent-task-thread',turn:{status:'completed'}}});
 }
 appendFileSync(${JSON.stringify(observation)},JSON.stringify({method:m.method,params:m.params})+'\\n');
 if(m.method==='initialize')return send({id:m.id,result:{}});
 if(m.method==='account/read')return send({id:m.id,result:{account:{type:'chatgpt'}}});
 if(m.method==='thread/start'||m.method==='thread/resume')return send({id:m.id,result:{thread:{id:'persistent-task-thread'}}});
 if(m.method==='command/exec'){
   const setup=m.params.command[1]==='install';
   if(setup)mkdirSync('node_modules',{recursive:true});
   const failed=setup?${mode === "setup_fail"}:(${mode === "fail"}||readFileSync('app.js','utf8')!=='fixed');
   return send({id:m.id,result:{exitCode:failed?1:0,stdout:'',stderr:failed?'Project check failed: expected fixed':''}});
 }
 if(m.method==='turn/start'){
  turn++;writeFileSync(${JSON.stringify(mode === "text" ? "prueba.txt" : "app.js")},${mode === "text" ? JSON.stringify("esto es una prueba") : "turn===1?'broken':'fixed'"});
  if(${Boolean(question)} && !${Boolean(question?.structured)}){send({id:m.id,result:{}});return send({id:'decision-request',method:'item/tool/requestUserInput',params:${JSON.stringify(question??{})}});}
  if(${Boolean(question?.structured)}){send({id:m.id,result:{}});send({method:'item/completed',params:{threadId:'persistent-task-thread',item:{type:'agentMessage',text:JSON.stringify({outcome:'blocked',decision:${JSON.stringify(question?.questions?.[0]??null)},blocker:{category:'missing_context',message:'Human decision required',question:'Approve the scope change?'}})}}});return send({method:'turn/completed',params:{threadId:'persistent-task-thread',turn:{status:'completed'}}});}
  send({id:m.id,result:{}});send({method:'item/completed',params:{threadId:'persistent-task-thread',item:{type:'agentMessage',text:JSON.stringify({outcome:'completed',summary:'Added the requested change',validation:${mode.startsWith("reported_")?"[{command:'pytest',status:'failed'}]":"[]"},blocker:null})}}});
  return send({method:'turn/completed',params:{threadId:'persistent-task-thread',turn:{status:'completed'}}});
 }
 send({id:m.id,result:{data:[]}});
});
`);
  await chmod(binary, 0o755);
  const state: JournalState = { lease: { id: "22222222-2222-4222-8222-222222222222", project_id: "11111111-1111-4111-8111-111111111111", generation: 1, lifecycle: 1, title: "Implement change", prompt: "Make the change", snapshot: { repository: "acme/app", base_branch: "main", instructions: "" } }, sequence: 0 };
  const journal = new Journal(join(root, "slot")), repositories = new RepositoryWorkspace({ remoteURL: () => remote });
  const events: any[] = [], publications: string[] = [], reviewInputs: any[] = [];
  let publicationAttempts=0,verificationAttempts=0,reviews=0,publishTokens=0,comments=0,lookups=0;
  if(reviewVerdict)state.lease.snapshot!.review_policy={version:1};
  if(question)state.lease.snapshot!.workflow_version=2;
  const api = { post: async (path: string, payload: any) => {
    if(path.endsWith('/clarifications/request')){events.push({kind:'question',data:payload});return {id:'decision-1',status:'awaiting_input'};}
    if (path.endsWith("github-token")) {
      if(payload.purpose==="publish")publishTokens++;
      if(failures.checkoutDuringPublish && state.phase==="publish" && payload.purpose==="checkout")throw new Error("Checkout transport interrupted");
      return { token: "fake-token", expires_at: "2099-01-01T00:00:00Z", author_name: "Test", author_email: "test@example.test" };
    }
    if (path.endsWith("events")) {
      events.push(payload.event);
      if(payload.event.kind==="candidate" && ++verificationAttempts<=(failures.verify??0))return {state:"running",verification:"pending"};
      return { state: ["candidate", "no_changes"].includes(payload.event.kind) ? "succeeded" : payload.event.kind === "blocked" ? "blocked" : "running" };
    }
    return { expires_in_ms: 90_000 };
  } };
  const run = () => execute({ version: 2, server: "http://localhost:4100", token: "test", codexBinary: binary }, api, journal, state, performance.now(), new AbortController().signal, {
    dataRoot: root, repositories,
    reviewer: reviewVerdict ? async input => { reviewInputs.push(input);reviews++;const verdict=Array.isArray(reviewVerdict)?reviewVerdict[Math.min(reviews-1,reviewVerdict.length-1)]:reviewVerdict;if(verdict==="invalid")throw new Error("Malformed review");return { ...reviewIdentity(input.lease,input.commit,input.baseline), verdict, summary:"Independent review",findings:verdict==="request_changes"?[{severity:"important",path:"prueba.txt",line:1,description:"Missing required error state",evidence:"No exception handling reaches the error display"}]:[],limitations:["Inspection only"] }; } : undefined,
    publisherFactory: context => ({
      reviewSnapshot: async (_commit:string, inspect:(path:string)=>Promise<unknown>) => inspect(context.workspace),
      changedFiles: async () => execFileSync("git", ["-C", context.workspace, "status", "--porcelain"], { encoding: "utf8" }).trim().split("\n").filter(Boolean).map(line => line.slice(3)),
      commit: async () => ({ changed: true, commit: "a".repeat(40) }),
      status: async () => ({ changed: true, commit: "a".repeat(40) }),
      summaryComment: async (_url:string,_commit:string,_body:string,_credential:unknown,_signal:unknown,lookupOnly=false) => {if(lookupOnly){lookups++;return "ambiguous";}comments++;return "sent";},
      publish: async (_title: string, body: string) => { if(++publicationAttempts<=(failures.publish??0))throw new Error("GitHub transport interrupted"); publications.push(body); return { repository: "acme/app", branch: context.branch, base_branch: "main", commit: "a".repeat(40), pr_url: "https://github.com/acme/app/pull/1" }; }
    } as any)
  });
  return { root, state, journal, events, publications, reviewInputs, run, reviewStats:()=>({reviews,publishTokens,comments,lookups}), observations: async () => (await readFile(observation, "utf8")).trim().split("\n").map(line => JSON.parse(line)) };
}

test("important or inconclusive independent review blocks before obtaining publish credentials", async () => {
  for(const verdict of ["request_changes","blocked"] as const) {
    const f=await fixture("text",{},verdict);
    try {await f.run();assert.equal(f.publications.length,0);assert.equal(f.reviewStats().publishTokens,0);assert.equal(f.events.at(-1).kind,"blocked");assert.equal(f.events.at(-1).data.category,"validation_failed");}
    finally {await rm(f.root,{recursive:true,force:true});}
  }
});

test("review receives connector validation and blocked results expose the review limitation", async () => {
  const f=await fixture("repair",{},"blocked");
  try {
    await f.run();
    assert.equal(f.reviewInputs.length,2);
    assert.deepEqual(f.reviewInputs[0].executedChecks,[{command:"npm run check",status:"passed"}]);
    assert.equal(f.publications.length,0);
    assert.match(f.events.at(-1).data.summary,/Inspection only/);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("routine agent questions never create a human wait",async()=>{
  const f=await fixture("text",{},undefined,{questions:[{id:"framework",header:"Framework",question:"Which framework?"}]});
  try {await f.run();assert.equal(f.events.filter(e=>e.kind==="question").length,0);assert.equal(f.publications.length,1);const answer=(await f.observations()).find(e=>e.method==="decision-answer");assert.match(answer.params.answers.framework.answers[0],/autonomously/);}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("important binary decisions park the conversation before any publication",async()=>{
  const q={id:"scope",header:"Scope",question:"Approve adding billing to the requested dashboard? This materially expands its scope.",options:[{label:"Approve",description:"Add billing"},{label:"Deny",description:"Keep the approved dashboard scope"}]};
  const f=await fixture("text",{},undefined,{questions:[q],turnId:"important-turn"});
  try {await f.run();assert.equal(f.events.filter(e=>e.kind==="question").length,1);assert.equal(f.publications.length,0);assert.equal(await f.journal.load(),null);const {existsSync}=await import("node:fs");assert.ok(existsSync(join(f.journal.continuationRoot,`${f.state.lease.id}-1`,"active.json")));}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("structured decision output parks safely when interactive input is unavailable",async()=>{
  const q={id:"scope",header:"Scope",question:"Approve adding billing? This expands the requested scope.",options:[{label:"Approve",description:"Add billing"},{label:"Deny",description:"Keep original scope"}]};
  const f=await fixture("text",{},undefined,{structured:true,questions:[q]});
  try {await f.run();assert.equal(f.events.filter(e=>e.kind==="question").length,1);assert.equal(f.publications.length,0);assert.equal(await f.journal.load(),null);const {existsSync}=await import("node:fs");assert.ok(existsSync(join(f.journal.continuationRoot,`${f.state.lease.id}-1`,"active.json")));}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("independent findings are repaired in the same task and freshly reviewed before publication",async()=>{
  const f=await fixture("text",{},["request_changes","approve"]);
  try {
    await f.run();
    assert.equal(f.publications.length,1);assert.equal(f.reviewStats().reviews,2);
    const turns=(await f.observations()).filter(x=>x.method==="turn/start");
    assert.equal(turns.length,2);assert.match(turns[1].params.input[0].text,/Missing required error state/);
    assert.equal(f.state.review_repairs,1);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("persistent review findings stop after two repairs without publishing",async()=>{
  const f=await fixture("text",{},"request_changes");
  try {await f.run();assert.equal(f.publications.length,0);assert.equal(f.reviewStats().reviews,3);assert.equal(f.state.review_repairs,2);assert.equal((await f.observations()).filter(x=>x.method==="turn/start").length,3);assert.equal(f.events.at(-1).kind,"blocked");}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("an incomplete review gets one fresh retry without rerunning implementation",async()=>{
  const f=await fixture("text",{},["invalid","approve"]);
  try {await f.run();assert.equal(f.publications.length,1);assert.equal(f.reviewStats().reviews,2);assert.equal((await f.observations()).filter(x=>x.method==="turn/start").length,1);}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("an inconclusive verdict is rechecked once before stopping the task",async()=>{
  const f=await fixture("text",{},["blocked","approve"]);
  try {await f.run();assert.equal(f.publications.length,1);assert.equal(f.reviewStats().reviews,2);}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("publication retry reuses only the exact independent approval without rerunning implementation", async () => {
  const f=await fixture("text",{publish:1},"approve");
  try {await assert.rejects(f.run());await f.run();assert.equal(f.reviewStats().reviews,1);assert.equal(f.publications.length,1);assert.match(f.publications[0],/Independent review/);assert.equal((await f.observations()).filter(x=>x.method==="turn/start").length,1);}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("recovery processes a saved blocking review before considering another approval",async()=>{
  const f=await fixture("text",{publish:1},"approve");
  try {
    await assert.rejects(f.run());
    f.state.review={...f.state.review!,verdict:"request_changes",findings:[{severity:"important",path:"prueba.txt",line:1,description:"Missing error state",evidence:"No error display path"}]};
    await f.journal.save(f.state);await f.run();
    assert.equal((await f.observations()).filter(e=>e.method==="turn/start").length,2);
    assert.equal(f.state.review_repairs,1);assert.equal(f.publications.length,1);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("interrupted review attempts consume a persisted total budget before launch",async()=>{
  const f=await fixture("text",{},"approve");
  try {f.state.review_attempts=4;await f.run();assert.equal(f.reviewStats().reviews,0);assert.equal(f.publications.length,0);assert.equal(f.events.at(-1).kind,"blocked");}
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("verification recovery delivers an unattempted summary and reconciles uncertain sends without reposting",async()=>{
  for(const status of ["ready","pending","ambiguous"] as const) {
    const f=await fixture("text",{},"approve");
    try {
      f.state.phase="verify";f.state.candidate={pr_url:"https://github.com/acme/app/pull/1",commit:"a".repeat(40)};
      f.state.result={outcome:"completed",summary:"Done",validation:[],blocker:null};
      f.state.summary_comment={commit:"a".repeat(40),status,body:"Detailed human context",context:{workspace:f.root,repository:"acme/app",branch:"task/test",baseBranch:"main",baseline:"b".repeat(40),gitDir:f.root,commonDir:f.root}};
      await f.run();
      assert.equal(f.reviewStats().comments,status==="ready"?1:0);
      assert.equal(f.reviewStats().lookups,status==="ready"?0:1);
      if(status!=="ready")assert.match(f.events.at(-1).data.summary,/PR context delivery unconfirmed/);
      assert.equal(f.publications.length,0);
    } finally {await rm(f.root,{recursive:true,force:true});}
  }
});

test("missing dependencies are prepared once and a failed validation is repaired in the same thread", async () => {
  const f = await fixture();
  try {
    await f.run(); const log = await f.observations();
    assert.equal(log.filter(x => x.method === "command/exec" && x.params.command[1] === "install").length, 1);
    assert.equal(log.filter(x => x.method === "thread/start").length, 1);
    assert.equal(log.filter(x => x.method === "thread/resume").length, 1);
    assert.equal(f.publications.length, 1);
    assert.match(f.publications[0], /npm run check: passed/);
    assert.equal(f.events.at(-1).kind, "candidate");
    assert.equal(await f.journal.load(), null);
  } finally { await rm(f.root, { recursive: true, force: true }); }
});

test("publication retries preserve the completed implementation instead of starting another agent turn", async () => {
  const f=await fixture("text",{publish:1});
  try {
    await assert.rejects(f.run(),/transport interrupted/);
    assert.equal((await f.journal.load())?.phase,"publish");
    await f.run();
    assert.equal((await f.observations()).filter(x=>x.method==="turn/start").length,1);
    assert.equal(f.publications.length,1);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("GitHub verification retries the same PR only, then retains its URL on exhaustion", async () => {
  const f=await fixture("text",{verify:3});
  try {
    await f.run();
    assert.equal((await f.observations()).filter(x=>x.method==="turn/start").length,1);
    assert.equal(f.publications.length,1);
    assert.equal(f.events.filter(x=>x.kind==="candidate").length,3);
    assert.equal(f.events.at(-1).kind,"blocked");
    assert.equal(f.events.at(-1).data.pr_url,"https://github.com/acme/app/pull/1");
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("failed dependency setup is bounded and never mislabeled as missing context", async () => {
  const f=await fixture("setup_fail");
  try { await f.run(); assert.equal(f.events.at(-1).data.category,"environment_setup_failed"); assert.equal(f.publications.length,0); }
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("an agent-reported failed check cannot be published when no deterministic check is configured", async () => {
  const f=await fixture("reported_fail");
  try { await f.run(); assert.equal(f.events.at(-1).data.category,"validation_failed"); assert.equal(f.publications.length,0); }
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("a passing Node check does not erase a failed check from another stack", async () => {
  const f=await fixture("reported_mixed");
  try { await f.run(); assert.equal(f.events.at(-1).data.category,"validation_failed"); assert.equal(f.publications.length,0); assert.ok(f.events.at(-1).data.validation.some((check:any)=>check.command==="pytest"&&check.status==="failed")); }
  finally {await rm(f.root,{recursive:true,force:true});}
});

test("publication prerequisite failures preserve the completed implementation and stop after three attempts", async () => {
  const failures={publish:1,checkoutDuringPublish:false};
  const f=await fixture("text",failures);
  try {
    await assert.rejects(f.run(),/transport interrupted/);
    failures.checkoutDuringPublish=true;
    await assert.rejects(f.run(),/Checkout transport interrupted/);
    assert.equal((await f.journal.load())?.phase,"publish");
    await f.run();
    assert.equal((await f.observations()).filter(x=>x.method==="turn/start").length,1);
    assert.equal(f.events.at(-1).kind,"blocked");
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("a restart after the third publication attempt cannot start a fourth attempt", async () => {
  const f=await fixture("text");
  try {
    f.state.phase="publish";f.state.publication_attempts=3;
    await f.run();
    assert.equal(f.state.publication_attempts,3);
    assert.equal(f.publications.length,0);
    assert.equal(f.events.length,1);
    assert.equal(f.events[0].data.category,"recovery_exhausted");
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("text-only work does not install dependencies or start project checks", async () => {
  const f = await fixture("text");
  try { await f.run(); assert.equal((await f.observations()).filter(x => x.method === "command/exec").length, 0); assert.equal(f.publications.length, 1); }
  finally { await rm(f.root, { recursive: true, force: true }); }
});

test("three failed validation attempts stop without publishing and report the failed check", async () => {
  const f = await fixture("fail");
  try {
    await f.run(); assert.equal((await f.observations()).filter(x => x.method === "turn/start").length, 3);
    assert.equal(f.publications.length, 0); assert.equal(f.events.at(-1).kind, "blocked");
    assert.equal(f.events.at(-1).data.category, "validation_failed");
    assert.match(f.events.at(-1).data.summary, /npm run check/);
  } finally { await rm(f.root, { recursive: true, force: true }); }
});

test("an expired saved deadline prevents another agent turn", async () => {
  const f = await fixture();
  try { f.state.deadline_at = Date.now() - 1; await f.run(); assert.equal(f.publications.length, 0); assert.equal(f.events.at(-1).data.category, "execution_timeout"); }
  finally { await rm(f.root, { recursive: true, force: true }); }
});

test("lost verification acknowledgement replays the candidate and preserves the verification checkpoint", async () => {
  const root = await mkdtemp(join(tmpdir(), "orchestrator-verify-recovery-"));
  try {
    const journal = new Journal(root);
    const state: JournalState = { lease: { id: "run", lifecycle: 1, generation: 1 }, sequence: 2, phase: "verify", candidate: { pr_url: "https://github.com/acme/app/pull/1" }, pending_event: { sequence: 2, kind: "candidate", data: {} } };
    await journal.save(state);
    const result = await recover({ post: async path => path.endsWith("events") ? { state: "running", verification: "pending" } : { action: "replay", expires_in_ms: 90_000 } }, journal);
    assert.equal(result?.phase, "verify"); assert.equal((await journal.load())?.candidate?.pr_url, "https://github.com/acme/app/pull/1");
  } finally { await rm(root, { recursive: true, force: true }); }
});
