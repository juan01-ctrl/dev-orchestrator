import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const root = new URL("../", import.meta.url);
const manifest = JSON.parse(await readFile(new URL("package.json", root), "utf8"));

test("connector package exposes a runnable CLI without publishing the monorepo", () => {
  assert.equal(manifest.private, undefined);
  assert.equal(manifest.bin?.["dev-orchestrator-connector"], "bin/dev-orchestrator-connector.js");
  assert.deepEqual(manifest.files, ["bin/", "dist/"]);
});

test("executor setup commands use the published connector release", async () => {
  const dashboard = await readFile(
    new URL("../platform/lib/dev_orchestrator_web/live/dashboard_live.ex", root),
    "utf8",
  );

  assert.equal(manifest.version, "0.1.4");
  assert.match(dashboard, new RegExp(`dev-orchestrator-connector@${manifest.version}`));
});

test("CLI wrapper targets built JavaScript instead of stripping TypeScript in node_modules", async () => {
  const wrapper = await readFile(new URL("bin/dev-orchestrator-connector.js", root), "utf8");

  assert.match(wrapper, /dist\/cli\.js/);
  assert.doesNotMatch(wrapper, /experimental-strip-types/);
});

test("installed CLI wrapper forwards help to the connector", () => {
  const result = spawnSync(process.execPath, ["bin/dev-orchestrator-connector.js", "help"], {
    cwd: new URL("../", import.meta.url),
    encoding: "utf8",
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Dev Orchestrator connector/);
  assert.match(result.stdout, /run --config FILE/);
});
