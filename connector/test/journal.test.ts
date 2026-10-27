import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Journal } from "../src/journal.ts";

test("a parked conversation survives restart and can resume on a different slot under a new generation",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-parked-"));
  try {
    const shared=join(root,"continuations");
    const first=new Journal(join(root,"slot-1"),shared);
    const state={lease:{id:"run-pause",lifecycle:1,generation:1,snapshot:{task_branch:"task/run-pause/attempt-1"}},sequence:4,attempts:2,review_repairs:1,review_failures:1,thread_id:"thread-1",workspace:"/preserved/workspace",baseline:"a".repeat(40)};
    await first.save(state);await first.park(state);
    assert.equal(await first.load(),null);
    const second=new Journal(join(root,"slot-2"),shared);
    const lease={...state.lease,generation:3,sequence:0,snapshot:{...state.lease.snapshot,execution_deadline_at_ms:Date.now()+60_000,continuation:{kind:"human_answer",questions:[{id:"q1",question:"Which?"}],answer:{answers:{q1:{answers:["A"]}}}}}};
    const resumed=await second.resumeContinuation(lease);
    assert.equal(resumed?.thread_id,"thread-1");
    assert.equal(resumed?.sequence,0);
    assert.equal(resumed?.lease.generation,3);
    assert.equal(resumed?.workspace,"/preserved/workspace");
    assert.equal(resumed?.deadline_at,lease.snapshot.execution_deadline_at_ms);
    assert.equal(resumed?.attempts,2);assert.equal(resumed?.review_repairs,1);assert.equal(resumed?.review_failures,1);
    assert.equal(resumed?.resume_interrupted_turn,true);
    assert.equal(await second.resumeContinuation(lease),null);
  } finally {await rm(root,{recursive:true,force:true});}
});

test("a pending final result survives restart and lost acknowledgement", async () => {
  const root = await mkdtemp(join(tmpdir(),"orchestrator-journal-"));
  try {
    const first = new Journal(root);
    await first.save({ lease: { id: "run-1", generation: 2, lifecycle: 1 }, sequence: 5, pending_event: { sequence: 5, kind: "candidate", data: { pr_url: "https://github.com/acme/app/pull/1" } } });
    const recovered = await new Journal(root).load();
    assert.equal(recovered?.pending_event?.kind, "candidate");
    assert.equal(recovered?.sequence, 5);
    await first.clear();
    assert.equal(await first.load(), null);
  } finally { await rm(root,{recursive:true,force:true}); }
});

test("execution retry continuations preserve consumed repair and review budgets",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-retry-budget-"));
  try {
    const journal=new Journal(join(root,"slot"));
    const state={lease:{id:"retry-budget",lifecycle:1,generation:1,snapshot:{task_branch:"task/retry-budget"}},sequence:0,thread_id:"thread",workspace:"/preserved",baseline:"a".repeat(40),attempts:2,review_repairs:2,review_failures:1,review_attempts:3};
    await journal.park(state);
    const resumed=await journal.resumeContinuation({...state.lease,generation:2,snapshot:{...state.lease.snapshot,continuation:{kind:"execution_retry"}}});
    assert.equal(resumed?.attempts,2);assert.equal(resumed?.review_repairs,2);assert.equal(resumed?.review_failures,1);assert.equal(resumed?.review_attempts,3);
  } finally {await rm(root,{recursive:true,force:true});}
});

test("execution retry retains saved blocking findings as focused repair input",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-retry-findings-"));
  try {
    const journal=new Journal(join(root,"slot"));
    const lease={id:"retry-findings",lifecycle:1,generation:1,snapshot:{task_branch:"task/retry-findings"}};
    await journal.park({lease,sequence:0,phase:"publish",thread_id:"thread",workspace:"/preserved",baseline:"a".repeat(40),attempts:1,review:{baseline:"a".repeat(40),commit:"b".repeat(40),generation:1,task_digest:"digest",verdict:"request_changes",summary:"Fix error handling",findings:[{severity:"important",path:"app.js",line:1,description:"Missing error display",evidence:"No failure path"}],limitations:[]}});
    const resumed=await journal.resumeContinuation({...lease,generation:2,snapshot:{...lease.snapshot,continuation:{kind:"execution_retry"}}});
    assert.match(resumed?.repair_context??"",/Missing error display/);assert.equal(resumed?.review_repairs,1);assert.equal(resumed?.result?.blocker?.category,"validation_failed");
  } finally {await rm(root,{recursive:true,force:true});}
});
