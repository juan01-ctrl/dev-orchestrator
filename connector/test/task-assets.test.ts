import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, realpath, readdir, rm, stat, symlink } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { materializeTaskAssets, taskAssetsPrompt } from "../src/task-assets.ts";
import type { Lease } from "../src/types.ts";

const file = Buffer.from("id,name\n1,alpha\n");
const hash = createHash("sha256").update(file).digest("hex");
const lease: Lease = { id: "22222222-2222-4222-8222-222222222222", generation: 1, lifecycle: 1, snapshot: { task_assets: [
  { id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", filename_hint: "../dataset.csv" }
], task_assets_skipped: 0 } };

test("materializes an asset with a safe name, private permissions, and an untrusted-reference prompt", async () => {
  const workspace = await realpath(await mkdtemp(join(tmpdir(), "orchestrator-assets-")));
  try {
    const report = await materializeTaskAssets({ downloadAsset: async () => ({ body: file, filename: "../dataset.csv", mediaType: "text/csv", sha256: hash }) }, lease, workspace);
    assert.equal(report.available.length, 1);
    const asset = report.available[0]!;
    assert.match(asset.relative_path, /^\.dev-orchestrator-context\/linear\/aaaaaaaaaaaa-dataset\.csv$/);
    assert.deepEqual(await readFile(join(workspace, asset.relative_path)), file);
    assert.equal((await stat(join(workspace, asset.relative_path))).mode & 0o777, 0o400);
    const prompt = taskAssetsPrompt(report, workspace);
    assert.match(prompt, /untrusted data/);
    assert.match(prompt, /dataset\.csv/);
    assert.doesNotMatch(prompt, /uploads\.linear\.app|private-source-url/);

    let downloaded = 0;
    const recovered = await materializeTaskAssets({ downloadAsset: async () => { downloaded++; throw new Error("should reuse verified file"); } }, lease, workspace, report);
    assert.equal(downloaded, 0);
    assert.deepEqual(recovered, report);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("unavailable optional files are reported without failing the task", async () => {
  const workspace = await realpath(await mkdtemp(join(tmpdir(), "orchestrator-assets-")));
  try {
    const report = await materializeTaskAssets({ downloadAsset: async () => { throw new Error("sensitive upstream detail"); } }, lease, workspace);
    assert.equal(report.available.length, 0);
    assert.equal(report.unavailable.length, 1);
    assert.match(report.unavailable[0]!.reason, /could not be downloaded/);
    assert.doesNotMatch(JSON.stringify(report), /sensitive upstream detail/);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("does not write through a task context directory replaced by a symlink", async () => {
  const workspace = await realpath(await mkdtemp(join(tmpdir(), "orchestrator-assets-")));
  const outside = await realpath(await mkdtemp(join(tmpdir(), "orchestrator-assets-outside-")));
  try {
    await symlink(outside, join(workspace, ".dev-orchestrator-context"));
    const report = await materializeTaskAssets({ downloadAsset: async () => ({ body: file, filename: "dataset.csv", mediaType: "text/csv", sha256: hash }) }, lease, workspace);
    assert.equal(report.available.length, 0);
    assert.equal(report.unavailable.length, 1);
    assert.deepEqual(await readdir(outside), []);
  } finally { await rm(workspace, { recursive: true, force: true }); await rm(outside, { recursive: true, force: true }); }
});

test("does not write files that exceed the per-run byte budget", async () => {
  const workspace = await realpath(await mkdtemp(join(tmpdir(), "orchestrator-assets-")));
  try {
    const many: Lease = { ...lease, snapshot: { task_assets: Array.from({ length: 10 }, (_, i) => ({ id: `${String(i + 1).padStart(8, "0")}-aaaa-4aaa-8aaa-aaaaaaaaaaaa`, filename_hint: `f${i}.csv` })) } };
    let calls = 0;
    const report = await materializeTaskAssets({ downloadAsset: async () => { calls++; const body = Buffer.alloc(3 * 1024 * 1024, 65); return { body, filename: "data.csv", mediaType: "text/csv", sha256: createHash("sha256").update(body).digest("hex") }; } }, many, workspace);
    assert.equal(calls, 9);
    assert.equal(report.available.length, 8);
    assert.equal(report.unavailable.length, 2);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});
