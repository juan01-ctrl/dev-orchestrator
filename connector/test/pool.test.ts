import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runPool, runSlots, slotCapacity } from "../src/pool.ts";

test("slot capacity is bounded and defaults to one", () => {
  assert.equal(slotCapacity(undefined), 1);
  assert.equal(slotCapacity("4"), 4);
  for (const invalid of ["0", "11", "1.5", "abc", "-1"]) assert.throws(() => slotCapacity(invalid));
});

test("a pre-aborted parent signal never starts a slot",async()=>{
  const controller=new AbortController();controller.abort();let started=0;
  await runSlots(2,controller.signal,async()=>{started++;});
  assert.equal(started,0);
});

test("slots execute concurrently with isolated identifiers and shared cancellation", async () => {
  const controller = new AbortController();
  const started: number[] = [];
  const promise = runSlots(2, controller.signal, async (slot, signal) => {
    started.push(slot);
    await new Promise<void>(resolve => signal.addEventListener("abort", () => resolve(), { once: true }));
  });
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.deepEqual(started.sort(), [1, 2]);
  controller.abort();
  await promise;
});

test("one failed slot is surfaced even while another slot is still polling", async () => {
  const controller = new AbortController();
  const pending = runSlots(2, controller.signal, async slot => {
    if (slot === 1) throw new Error("slot startup failed");
    await new Promise<void>(() => {});
  });
  await assert.rejects(Promise.race([
    pending,
    new Promise((_, reject) => setTimeout(() => reject(new Error("slot failure was hidden")), 100))
  ]), /slot startup failed/);
});

test("a cancelled pool creates no runtime directories or Codex processes", async () => {
  const root = await mkdtemp(join(tmpdir(), "connector-slots-"));
  try {
    const controller = new AbortController();
    controller.abort();
    await runPool({ version: 2, server: "http://127.0.0.1:4100", token: "test", codexBinary: "missing-codex-test-binary" }, root, controller.signal, 1);
    await assert.rejects(stat(join(root, "slots", "1")), {code:"ENOENT"});
  } finally { await rm(root, { recursive: true, force: true }); }
});
