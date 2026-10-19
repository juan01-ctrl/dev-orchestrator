import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Journal } from "../src/journal.ts";
import { recover, emitDurably } from "../src/worker.ts";

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
