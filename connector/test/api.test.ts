import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { API } from "../src/api.ts";

const lease = { id: "22222222-2222-4222-8222-222222222222", generation: 3, lifecycle: 1 };
const bytes = Buffer.from("id,name\n1,alpha\n");
const digest = createHash("sha256").update(bytes).digest("hex");

test("downloads a binary task asset with executor auth and verifies integrity metadata", async () => {
  const original = globalThis.fetch;
  let request: Request | undefined;
  globalThis.fetch = async (input, init) => {
    request = new Request(input, init);
    return new Response(bytes, { status: 200, headers: {
      "content-type": "text/csv; charset=utf-8",
      "content-disposition": 'attachment; filename="dataset.csv"',
      "x-dev-orchestrator-size": String(bytes.length),
      "x-dev-orchestrator-sha256": digest
    } });
  };
  try {
    const result = await new API("https://orchestrator.example", "executor-secret").downloadAsset(lease, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    assert.deepEqual(result, { body: bytes, filename: "dataset.csv", mediaType: "text/csv", sha256: digest });
    assert.equal(request?.method, "POST");
    assert.equal(request?.headers.get("authorization"), "Bearer executor-secret");
    assert.deepEqual(await request?.json(), { lease, asset_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" });
    assert.equal(request?.redirect, "error");
  } finally { globalThis.fetch = original; }
});

test("rejects a response whose streamed size disagrees with its authenticated metadata", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(bytes, { status: 200, headers: {
    "content-type": "text/csv", "content-disposition": 'attachment; filename="data.csv"',
    "x-dev-orchestrator-size": String(bytes.length + 1), "x-dev-orchestrator-sha256": digest
  } });
  try {
    await assert.rejects(new API("https://orchestrator.example", "token").downloadAsset(lease, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), /integrity check failed/);
  } finally { globalThis.fetch = original; }
});

test("does not trust a declared response size above the per-file limit", async () => {
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, { status: 200, headers: {
    "content-type": "text/csv", "content-disposition": 'attachment; filename="data.csv"',
    "x-dev-orchestrator-size": String(11 * 1024 * 1024), "x-dev-orchestrator-sha256": digest
  } });
  try {
    await assert.rejects(new API("https://orchestrator.example", "token").downloadAsset(lease, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), /metadata is invalid/);
  } finally { globalThis.fetch = original; }
});
