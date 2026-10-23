import test from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ConnectorLock } from "../src/lock.ts";

test("refuses to remove a connector lock owned by a live process", async () => {
  const root = await mkdtemp(join(tmpdir(), "orchestrator-lock-live-"));
  const path = join(root, "connector.lock");
  try {
    await writeFile(path, `${process.pid}\n`);
    await chmod(path, 0o600);
    await assert.rejects(ConnectorLock.acquire(path), /already running/i);
    assert.equal(await readFile(path, "utf8"), `${process.pid}\n`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("recovers a stale connector lock and releases only the acquired lock", async () => {
  const root = await mkdtemp(join(tmpdir(), "orchestrator-lock-stale-"));
  const path = join(root, "connector.lock");
  try {
    await writeFile(path, "2147483647\n");
    await chmod(path, 0o600);
    const lock = await ConnectorLock.acquire(path);
    const state = JSON.parse(await readFile(path, "utf8"));
    assert.equal(state.pid, process.pid);
    assert.equal(typeof state.token, "string");
    await lock.release();
    await assert.rejects(readFile(path), { code: "ENOENT" });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("fails closed on a malformed or unsafe connector lock", async () => {
  const root = await mkdtemp(join(tmpdir(), "orchestrator-lock-invalid-"));
  const path = join(root, "connector.lock");
  try {
    await writeFile(path, "not-a-pid\n");
    await chmod(path, 0o600);
    await assert.rejects(ConnectorLock.acquire(path), /invalid|unsafe/i);
    assert.equal(await readFile(path, "utf8"), "not-a-pid\n");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
