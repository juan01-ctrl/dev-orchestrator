import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, mkdir, writeFile, chmod, readFile, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { Journal } from "../src/journal.ts";
import { recover, emitDurably, execute, waitForClarification } from "../src/worker.ts";
import { execFileSync } from "node:child_process";
import { RepositoryWorkspace } from "../src/repository.ts";
import { Publisher } from "../src/publisher.ts";

test("lost final acknowledgement replays the same event instead of rerunning Codex",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-worker-"));
  try {
    const journal=new Journal(root);
    const state={lease:{id:"run-1",generation:1,lifecycle:1},sequence:0};
    const paths:string[]=[];
    const offline={post:async(path:string)=>{paths.push(path);throw new Error("offline");}};
    await assert.rejects(emitDurably(offline,journal,state,"candidate",{pr_url:"https://github.com/acme/app/pull/1"}));
    assert.equal((await journal.load())?.pending_event?.sequence,1);
    const server={post:async(path:string,payload:any)=>{
      paths.push(path);
      if(path==="/executor/reconcile")return {action:"replay",expires_in_ms:90_000};
      assert.equal(path,"/executor/events");assert.equal(payload.event.sequence,1);return "duplicate";
    }};
    await recover(server,journal);
    assert.equal(await journal.load(),null);
    assert.deepEqual(paths,["/executor/events","/executor/reconcile","/executor/events"]);
  } finally {await rm(root,{recursive:true,force:true});}
});

test("a lease with no pending result is reconciled, never automatically re-executed",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-reconcile-"));
  try {
    const journal=new Journal(root);
    await journal.save({lease:{id:"run-1",generation:1,lifecycle:1},sequence:1});
    await recover({post:async(path:string)=>{assert.equal(path,"/executor/reconcile");return {action:"acknowledge",state:"blocked"};}},journal);
    assert.equal(await journal.load(),null);
  } finally {await rm(root,{recursive:true,force:true});}
});

test("an active journal with a Codex thread resumes without clearing its worktree state",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-thread-recovery-"));
  try {
    const journal=new Journal(root);
    const state={lease:{id:"run-resume",generation:2,lifecycle:1},sequence:4,thread_id:"thread-codex-1",workspace:"/workspace/run-resume",baseline:"a".repeat(40)};
    await journal.save(state);
    let payload:any;
    const recovered=await recover({post:async(path:string,body:any)=>{assert.equal(path,"/executor/reconcile");payload=body;return {action:"resume",state:"running",expires_in_ms:90_000};}},journal);
    assert.equal(payload.journal.thread_id,"thread-codex-1");
    assert.deepEqual(recovered,{...state,lease:{...state.lease,expires_in_ms:90_000}});
    assert.deepEqual(await journal.load(),{...state,lease:{...state.lease,expires_in_ms:90_000}});
  } finally {await rm(root,{recursive:true,force:true});}
});

test("clarification waits for the persisted answer and returns Codex's response shape",async()=>{
  const lease={id:"run-clarify",generation:3,lifecycle:1};
  const paths:string[]=[];
  const answer={answers:{framework:{answers:["Phoenix"]}}};
  const result=await waitForClarification({post:async(path:string,payload:any)=>{
    paths.push(path);
    assert.deepEqual(payload.lease,lease);
    if(path.endsWith("/request"))return {id:"clarification-1",status:"open"};
    return {status:"answered",answer};
  }},lease,{turnId:"turn-1",questions:[{id:"framework",question:"Which framework?"}]},undefined,0);
  assert.deepEqual(result,{response:answer,expired:false});
  assert.deepEqual(paths,["/executor/clarifications/request","/executor/clarifications/status"]);
});

test("clarification timeout resolves with no answers instead of inventing context",async()=>{
  const lease={id:"run-clarify-timeout",generation:1,lifecycle:1};
  const result=await waitForClarification({post:async()=>({status:"expired"})},lease,{questions:[]});
  assert.deepEqual(result,{response:{answers:{}},expired:true});
});

test("the worker bootstraps a repo, runs Codex, publishes a PR and keeps credentials out of the agent",async()=>{
  const root=await realpath(await mkdtemp(join(tmpdir(),"orchestrator-worker-instructions-")));
  try {
    const source=join(root,"source"),remote=join(root,"remote.git"),journalRoot=join(root,"runtime");
    await mkdir(source);await mkdir(remote);
    const git=(args:string[])=>execFileSync("git",["-C",source,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
    git(["init","-b","main"]);git(["config","user.name","Test"]);git(["config","user.email","test@example.test"]);
    await writeFile(join(source,"README.md"),"source\n");git(["add","README.md"]);git(["commit","-m","initial"]);
    execFileSync("git",["-C",remote,"init","--bare"],{stdio:"ignore"});
    git(["remote","add","origin",remote]);git(["push","origin","main"]);
    const projectId="11111111-1111-4111-8111-111111111111";
    const runId="22222222-2222-4222-8222-222222222222";
    const instructions="# Team guidance\nKeep changes focused.\n";
    const observation=join(root,"codex-observation.json");
    const binary=join(root,"fake-codex.mjs");
    await writeFile(binary,`#!/usr/bin/env node
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
const observation=${JSON.stringify(observation)};
let buffer="";
const respond=(value)=>process.stdout.write(JSON.stringify(value)+"\\n");
process.stdin.setEncoding("utf8");
process.stdin.on("data",chunk=>{
  buffer+=chunk;
  let end;
  while((end=buffer.indexOf("\\n"))>=0){
    const message=JSON.parse(buffer.slice(0,end));buffer=buffer.slice(end+1);
    if(message.method==="initialize")respond({id:message.id,result:{}});
    if(message.method==="permissionProfile/list")respond({id:message.id,result:{data:[{id:"dev-orchestrator"}],nextCursor:null}});
    if(message.method==="account/read")respond({id:message.id,result:{account:{type:"chatgpt"}}});
    if(message.method==="thread/start")respond({id:message.id,result:{thread:{id:"fake-thread"}}});
    if(message.method==="turn/start"){
const prompt=message.params.input[0].text;
      const privatePath=prompt.match(/read and follow the file at (.+) before making changes\./)?.[1];
      writeFileSync("README.md","implemented by Codex\\n");
      execFileSync("git",["add","README.md"]);
      execFileSync("git",["commit","-m","feat: update project readme"]);
      appendFileSync(observation,JSON.stringify({prompt,content:privatePath?readFileSync(privatePath,"utf8"):null,githubToken:process.env.GITHUB_TOKEN??null,status:execFileSync("git",["status","--porcelain"],{encoding:"utf8"})}));
      respond({id:message.id,result:{}});
      respond({method:"turn/started",params:{threadId:"fake-thread",turn:{id:"turn-1"}}});
      respond({method:"item/started",params:{threadId:"fake-thread",turnId:"turn-1",item:{type:"fileChange",id:"edit-1",changes:[{path:"README.md"}]}}});
      respond({method:"item/started",params:{threadId:"fake-thread",turnId:"turn-1",item:{type:"commandExecution",id:"command-1",command:"npm test"}}});
      respond({method:"item/completed",params:{threadId:"fake-thread",turnId:"turn-1",item:{type:"commandExecution",id:"command-1",command:"npm test",exitCode:0,status:"completed",aggregatedOutput:"private test output"}}});
      respond({method:"item/completed",params:{threadId:"fake-thread",item:{type:"agentMessage",text:JSON.stringify({outcome:"completed"})}}});
      respond({method:"turn/completed",params:{threadId:"fake-thread",turn:{status:"completed"}}});
    }
  }
});
`);
    await chmod(binary,0o755);

    const events:{kind:string;data:Record<string,unknown>}[]=[];
    const credentials:string[]=[];
    await execute(
      {version:2,server:"http://127.0.0.1:4100",token:"test",codexBinary:binary},
      {post:async(path:string,payload:any)=>{if(path==="/executor/github-token"){credentials.push(payload.purpose);return {token:`short-lived-${payload.purpose}-token`,expires_at:"2099-01-01T00:00:00Z",author_name:"test-app[bot]",author_email:"12345+test-app[bot]@users.noreply.github.com"};}if(path==="/executor/events"){events.push({kind:payload.event.kind,data:payload.event.data});if(payload.event.kind==="candidate")return {state:"succeeded"};}return {expires_in_ms:90_000};}},
      new Journal(journalRoot),
      {lease:{id:runId,generation:1,lifecycle:1,project_id:projectId,title:"Test task",prompt:"Do nothing",snapshot:{repository:"acme/app",base_branch:"main",instructions}},sequence:0},
      performance.now(),
      new AbortController().signal,
      {dataRoot:root,repositories:new RepositoryWorkspace({remoteURL:()=>remote}),publisherFactory:context=>new Publisher(context,{remoteURL:()=>remote,apiFetch:async(_url,init)=>{
        if(init?.method==="GET")return new Response("[]",{status:200});
        const commit=execFileSync("git",["--git-dir",remote,"rev-parse",`refs/heads/task/${runId}`],{encoding:"utf8"}).trim();
        return new Response(JSON.stringify({state:"open",head:{sha:commit,ref:`task/${runId}`,repo:{full_name:"acme/app"}},base:{ref:"main",repo:{full_name:"acme/app"}},html_url:"https://github.com/acme/app/pull/1"}),{status:201});
      }})}
    );

    const result=JSON.parse(await readFile(observation,"utf8"));
    assert.equal(result.content,instructions);
    assert.match(result.prompt,/Project instructions: read and follow the file at /);
    assert.equal(result.githubToken,null);
    assert.deepEqual(events.filter(event=>event.kind!=="activity").map(event=>event.kind==="progress"?event.data.stage:event.kind),[
      "started","repository_preparing","workspace_ready","agent_started","editing","validating","checks_passed","publishing","pr_verifying","candidate"
    ]);
    assert.ok(events.some(event=>event.kind==="activity"));
    assert.deepEqual(events.at(-1)?.data.repository,"acme/app");
    assert.deepEqual(events.at(-1)?.data.branch,`task/${runId}`);
    assert.deepEqual(events.at(-1)?.data.base_branch,"main");
    assert.deepEqual(events.at(-1)?.data.pr_url,"https://github.com/acme/app/pull/1");
    assert.equal(JSON.stringify(events).includes("private test output"),false);
    assert.deepEqual(credentials,["checkout","publish"]);
    assert.equal(JSON.stringify(events).includes("short-lived-checkout-token"),false);
    assert.equal(JSON.stringify(events).includes("short-lived-publish-token"),false);
    assert.equal(await new Journal(journalRoot).load(),null);
    const worktree=join(root,"workspaces",`${runId}-1`);
    const gitdirPointer=(await readFile(join(worktree,".git"),"utf8")).trim().replace(/^gitdir: /,"");
    assert.equal(JSON.parse(await readFile(join(resolve(worktree,gitdirPointer),"terminal.json"),"utf8")).outcome,"success");
  } finally {await rm(root,{recursive:true,force:true});}
});
