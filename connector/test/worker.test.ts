import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, mkdir, writeFile, chmod, readFile, realpath } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Journal } from "../src/journal.ts";
import { recover, emitDurably, execute } from "../src/worker.ts";
import { execFileSync } from "node:child_process";

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

test("the worker writes and directs Codex to project instructions before its task starts",async()=>{
  const root=await realpath(await mkdtemp(join(tmpdir(),"orchestrator-worker-instructions-")));
  try {
    const source=join(root,"source"),workspaces=join(root,"workspaces"),journalRoot=join(root,"journal");
    await mkdir(source);await mkdir(workspaces);
    const git=(args:string[])=>execFileSync("git",["-C",source,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
    git(["init","-b","main"]);git(["config","user.name","Test"]);git(["config","user.email","test@example.test"]);
    await writeFile(join(source,"README.md"),"source\n");git(["add","README.md"]);git(["commit","-m","initial"]);
    git(["remote","add","origin","https://github.com/acme/app.git"]);
    const projectId="11111111-1111-4111-8111-111111111111";
    const runId="22222222-2222-4222-8222-222222222222";
    const instructions="# Team guidance\nKeep changes focused.\n";
    const observation=join(root,"codex-observation.json");
    const binary=join(root,"fake-codex.mjs");
    await writeFile(binary,`#!/usr/bin/env node
import { appendFileSync, readFileSync } from "node:fs";
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
    if(message.method==="account/read")respond({id:message.id,result:{account:{type:"chatgpt"}}});
    if(message.method==="thread/start")respond({id:message.id,result:{thread:{id:"fake-thread"}}});
    if(message.method==="turn/start"){
      const privatePath=join(process.cwd(),".git","WORKFLOW.md");
      appendFileSync(observation,JSON.stringify({prompt:message.params.input[0].text,content:readFileSync(privatePath,"utf8")}));
      respond({id:message.id,result:{}});
      respond({method:"item/completed",params:{threadId:"fake-thread",item:{type:"agentMessage",text:JSON.stringify({outcome:"completed"})}}});
      respond({method:"turn/completed",params:{threadId:"fake-thread",turn:{status:"completed"}}});
    }
  }
});
`);
    await chmod(binary,0o755);

    const events:string[]=[];
    await execute(
      {version:1,server:"http://127.0.0.1:4100",token:"test",codexBinary:binary,mappings:[{projectId,repository:"acme/app",baseBranch:"main",source,workspaceRoot:workspaces}]},
      {post:async(path:string,payload:any)=>{if(path==="/executor/events")events.push(payload.event.kind);return {expires_in_ms:90_000};}},
      new Journal(journalRoot),
      {lease:{id:runId,generation:1,lifecycle:1,project_id:projectId,title:"Test task",prompt:"Do nothing",snapshot:{repository:"acme/app",base_branch:"main",instructions}},sequence:0},
      performance.now(),
      new AbortController().signal
    );

    const result=JSON.parse(await readFile(observation,"utf8"));
    assert.equal(result.content,instructions);
    assert.match(result.prompt,/\.git\/WORKFLOW\.md/);
    assert.deepEqual(events,["started","no_changes"]);
  } finally {await rm(root,{recursive:true,force:true});}
});
