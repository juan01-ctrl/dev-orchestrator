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
    const state={lease:{id:"run-pause",lifecycle:1,generation:1,snapshot:{task_branch:"task/run-pause/attempt-1"}},sequence:4,thread_id:"thread-1",workspace:"/preserved/workspace",baseline:"a".repeat(40)};
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
