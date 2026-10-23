import { join } from "node:path";
import { mkdir } from "node:fs/promises";
import type { Config } from "./types.ts";
import { runLoop } from "./worker.ts";

export function slotCapacity(value = process.env.DEV_ORCHESTRATOR_SLOTS): number {
  if (value === undefined || value === "") return 1;
  if (!/^[1-9]\d?$/.test(value)) throw new Error("DEV_ORCHESTRATOR_SLOTS must be an integer from 1 to 10.");
  const capacity = Number(value);
  if (capacity > 10) throw new Error("DEV_ORCHESTRATOR_SLOTS must be an integer from 1 to 10.");
  return capacity;
}

export async function runSlots(capacity: number, signal: AbortSignal, worker: (slot: number, signal: AbortSignal) => Promise<void>): Promise<void> {
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 10) throw new Error("Executor capacity must be from 1 to 10.");
  const controller = new AbortController();
  const stop = () => controller.abort();
  signal.addEventListener("abort", stop, { once: true });
  try {
    await Promise.all(Array.from({ length: capacity }, (_, index) => worker(index + 1, controller.signal)));
  } finally {
    controller.abort();
    signal.removeEventListener("abort", stop);
  }
}

export async function runPool(config: Config, runtimeRoot: string, signal: AbortSignal, capacity = slotCapacity()): Promise<void> {
  await runSlots(capacity, signal, async (slot, slotSignal) => {
    const slotRoot = join(runtimeRoot, "slots", String(slot));
    await mkdir(slotRoot, { recursive: true, mode: 0o700 });
    await runLoop(config, slotRoot, slotSignal, runtimeRoot);
  });
}
