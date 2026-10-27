import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { detectEnvironment, needsValidation, runEnvironmentCommands, validationContractError } from "../src/environment.ts";
import * as environment from "../src/environment.ts";

test("additive test scripts preserve original validation and run the added checks",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-additive-checks-"));
  try {
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{build:"astro build"}}));
    const original=await detectEnvironment(root);
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{build:"astro build",test:"node --test tests/*.test.mjs"}}));
    const current=await detectEnvironment(root);
    assert.equal(validationContractError(["package.json","src/app.ts"],original,current),undefined);
    assert.deepEqual(environment.validationPlan(original,current).validate,[["npm","run","build"],["npm","run","test"]]);
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{build:"astro build",test:"node --test tests/*.test.mjs",prebuild:"node weaken-checks.js"}}));
    assert.match(validationContractError(["package.json"],original,await detectEnvironment(root))??"",/changed/);
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{build:"echo passed",test:"node --test tests/*.test.mjs"}}));
    assert.match(validationContractError(["package.json"],original,await detectEnvironment(root))??"",/changed/);
  } finally {await rm(root,{recursive:true,force:true});}
});

test("validation cannot disappear or change its command definition after the initial plan", async () => {
  const root=await mkdtemp(join(tmpdir(),"orchestrator-check-contract-"));
  try {
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{test:"node --test"}}));
    const original=await detectEnvironment(root);
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{test:"echo passed"}}));
    assert.match(validationContractError(["src/app.ts"],original,await detectEnvironment(root))??"",/changed/);
    await writeFile(join(root,"package.json"),"{}");
    assert.match(validationContractError(["src/app.ts"],original,await detectEnvironment(root))??"",/changed/);
    const missing=await detectEnvironment(root);
    assert.match(validationContractError(["app.py"],missing,missing)??"",/not configured/);
    assert.equal(validationContractError(["README.md"],missing,missing),undefined);
  } finally {await rm(root,{recursive:true,force:true});}
});

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

test("a project without existing checks can add its first test without weakening a baseline",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-first-check-"));
  try {
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{dev:"astro dev"}}));
    const original=await detectEnvironment(root);
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{dev:"astro dev",test:"node --test"}}));
    const current=await detectEnvironment(root);
    assert.equal(validationContractError(["src/app.js"],original,current),undefined);
    assert.deepEqual(environment.validationPlan(original,current).validate,[["npm","run","test"]]);
  } finally {await rm(root,{recursive:true,force:true});}
});

test("explicit validation keeps frozen commands and executes failing newly added tests",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-explicit-added-check-"));
  try {
    await writeFile(join(root,".dev-orchestrator.json"),JSON.stringify({validate:[["npm","run","build"]]}));
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{build:"astro build"}}));
    const original=await detectEnvironment(root);
    await writeFile(join(root,"package.json"),JSON.stringify({scripts:{build:"astro build",test:"node --test"}}));
    const current=await detectEnvironment(root);
    assert.equal(validationContractError(["package.json"],original,current),undefined);
    const plan=environment.validationPlan(original,current);
    assert.deepEqual(plan.validate,[["npm","run","build"],["npm","run","test"]]);
    const result=await runEnvironmentCommands(plan.validate,async argv=>({exitCode:argv[2]==="test"?1:0,stdout:"",stderr:"Test assertion failed"}));
    assert.equal(result.failure?.category,"validation_failed");assert.equal(result.checks.at(-1)?.command,"npm run test");
  } finally {await rm(root,{recursive:true,force:true});}
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
