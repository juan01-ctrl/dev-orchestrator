import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serverURL, saveConfig, loadConfig } from "../src/config.ts";

test("remote transport requires HTTPS without URL credentials or paths", () => {
  assert.equal(serverURL("https://control.example/"), "https://control.example");
  assert.equal(serverURL("http://127.0.0.1:4100"), "http://127.0.0.1:4100");
  for (const value of ["http://control.example", "https://u:p@control.example", "https://control.example/a", "file:///tmp/config", "https://control.example/?token=x"]) {
    assert.throws(() => serverURL(value));
  }
});

test("paired credentials are private, round-trip and cannot overwrite an existing pairing", async () => {
  const dir = await mkdtemp(join(tmpdir(), "orchestrator-config-"));
  try {
    const file = join(dir, "connector.json");
    const config = { version: 2 as const, server: "https://control.example", token: "test-credential" };
    await saveConfig(file, config, true);
    assert.deepEqual(await loadConfig(file), config);
    assert.equal((await stat(file)).mode & 0o777, 0o600);
    await assert.rejects(saveConfig(file, config, true));
    assert.equal(JSON.parse(await readFile(file,"utf8")).token, "test-credential");
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("version 1 configs migrate in memory and ignore unsafe local project mappings", async () => {
  const dir = await mkdtemp(join(tmpdir(), "orchestrator-config-v1-"));
  try {
    const file = join(dir, "connector.json");
    await saveConfig(file, { version: 1 as any, server: "https://control.example", token: "test-credential", mappings: [{ source: "/stale/path" }] } as any, true);
    const loaded = await loadConfig(file);
    assert.deepEqual(loaded, { version: 2, server: "https://control.example", token: "test-credential" });
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test("new configs reject unsupported versions and project mappings", async () => {
  const dir = await mkdtemp(join(tmpdir(), "orchestrator-config-invalid-"));
  try {
    const file = join(dir, "connector.json");
    await saveConfig(file, { version: 2, server: "https://control.example", token: "test-credential", mappings: [] } as any, true);
    await assert.rejects(loadConfig(file), /Invalid connector configuration/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
