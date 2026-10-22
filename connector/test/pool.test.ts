import test from "node:test";
import assert from "node:assert/strict";
import { runSlots, slotCapacity } from "../src/pool.ts";

test("slot capacity is bounded and defaults to one", () => {
  assert.equal(slotCapacity(undefined), 1);
  assert.equal(slotCapacity("4"), 4);
  for (const invalid of ["0", "11", "1.5", "abc", "-1"]) assert.throws(() => slotCapacity(invalid));
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
