import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { detectEnvironment, needsValidation, runEnvironmentCommands } from "../src/environment.ts";

test("Node setup follows the lockfile, selects existing checks and skips text-only work", async () => {
  const root = await mkdtemp(join(tmpdir(), "orchestrator-environment-"));
  try {
    await writeFile(join(root, "package.json"), JSON.stringify({ scripts: { check: "astro check", build: "astro build" } }));
    await writeFile(join(root, "package-lock.json"), "{}");
    const plan = await detectEnvironment(root);
    assert.deepEqual(plan.setup, [["npm", "ci", "--no-audit", "--no-fund"]]);
    assert.deepEqual(plan.validate, [["npm", "run", "check"]]);
    assert.equal(needsValidation(["README.md", "prueba.txt"], plan), false);
    assert.equal(needsValidation(["src/pages/index.astro"], plan), true);
    assert.equal(needsValidation(["src/pages/signup.mdx"], plan), true);
    await writeFile(join(root, "package-lock.json"), '{"lockfileVersion":3}');
    assert.notEqual((await detectEnvironment(root)).fingerprint, plan.fingerprint);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("repository argv commands support other stacks and reject invalid or symlinked configuration", async () => {
  const root = await mkdtemp(join(tmpdir(), "orchestrator-environment-"));
  try {
    await writeFile(join(root, ".dev-orchestrator.json"), JSON.stringify({ setup: [["mix", "deps.get"]], validate: [["mix", "test"]] }));
    const plan = await detectEnvironment(root);
    assert.deepEqual(plan.validate, [["mix", "test"]]);
    assert.equal(needsValidation(["README.md"], plan), true);
    await writeFile(join(root, ".dev-orchestrator.json"), JSON.stringify({ setup: "curl something | sh" }));
    await assert.rejects(detectEnvironment(root), /configuration/i);
    await rm(join(root, ".dev-orchestrator.json"));
    await symlink("/etc/hosts", join(root, ".dev-orchestrator.json"));
    await assert.rejects(detectEnvironment(root), /configuration/i);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("command failures retain private diagnostics for recovery but expose a bounded category", async () => {
  const result = await runEnvironmentCommands([["npm", "run", "check"]], async () => ({ exitCode: 127, stdout: "", stderr: "sh: astro: command not found" }));
  assert.equal(result.checks[0].status, "failed");
  assert.equal(result.failure?.category, "environment_setup_failed");
  assert.match(result.failure?.diagnostic ?? "", /astro: command not found/);
});

test("sandbox command start failures return a failed check rather than restarting the whole task", async () => {
  const result = await runEnvironmentCommands([["npm", "ci"]], async () => { throw new Error("npm could not start (ENOENT)"); });
  assert.equal(result.checks[0].status,"failed");
  assert.equal(result.failure?.category,"environment_setup_failed");
});

test("transient network failures retry the command, not the agent", async () => {
  let attempts=0;
  const result=await runEnvironmentCommands([["npm","ci"]],async()=>({exitCode:++attempts<3?1:0,stdout:"",stderr:"ECONNRESET"}));
  assert.equal(attempts,3);
  assert.equal(result.failure,undefined);
  assert.equal(result.checks[0].status,"passed");
});
