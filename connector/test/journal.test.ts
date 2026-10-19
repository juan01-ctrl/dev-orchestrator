import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Journal } from "../src/journal.ts";

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
