import test from "node:test";
import assert from "node:assert/strict";
import { resolveServerRequest } from "../../src/app-server/requests.ts";

test("in-policy command and file requests are approved and out-of-policy requests are denied", async () => {
  const resolution = await resolveServerRequest({
    authorizeCommand: async params => params.command === "npm test",
    authorizeFileChange: async params => params.threadId === "thread-1"
  }, [
    { id: 1, method: "item/commandExecution/requestApproval", params: { command: "npm test" } },
    { id: 2, method: "item/commandExecution/requestApproval", params: { command: "curl unknown" } },
    { id: 3, method: "item/fileChange/requestApproval", params: { threadId: "thread-1" } }
  ]);

  assert.deepEqual(resolution, [
    { id: 1, result: { decision: "accept" } },
    { id: 2, result: { decision: "decline" } },
    { id: 3, result: { decision: "accept" } }
  ]);
});

test("missing context, permission expansion, MCP elicitation, and dynamic tools reach typed handlers", async () => {
  const calls: string[] = [];
  const resolution = await resolveServerRequest({
    requestUserInput: async () => { calls.push("input"); return { answers: { context: { answers: ["Use the existing API"] } } }; },
    requestPermissions: async () => { calls.push("permissions"); return { permissions: {}, scope: "turn" }; },
    requestElicitation: async () => { calls.push("elicitation"); return { action: "decline", content: null, _meta: null }; },
    callDynamicTool: async () => { calls.push("tool"); return { success: true, contentItems: [{ type: "text", text: "issue found" }] }; }
  }, [
    { id: 4, method: "item/tool/requestUserInput", params: {} },
    { id: 5, method: "item/permissions/requestApproval", params: {} },
    { id: 6, method: "mcpServer/elicitation/request", params: {} },
    { id: 7, method: "item/tool/call", params: {} }
  ]);

  assert.deepEqual(calls, ["input", "permissions", "elicitation", "tool"]);
  assert.deepEqual(resolution.map(item => item.id), [4, 5, 6, 7]);
  assert.deepEqual(resolution[0]?.result, { answers: { context: { answers: ["Use the existing API"] } } });
});

test("unsupported requests fail closed without throwing away the app-server session", async () => {
  const [resolution] = await resolveServerRequest({}, [{ id: 8, method: "unknown/request", params: {} }]);
  assert.equal(resolution?.error?.code, -32601);
});

test("command broker preserves the exact policy amendment response", async () => {
  const amendment = { host: "registry.npmjs.org", action: "allow" };
  const [resolution] = await resolveServerRequest({ authorizeCommand: () => ({ applyNetworkPolicyAmendment: { network_policy_amendment: amendment } }) }, [
    { id: "network-1", method: "item/commandExecution/requestApproval", params: { command: "npm install" } }
  ]);
  assert.deepEqual(resolution?.result, { decision: { applyNetworkPolicyAmendment: { network_policy_amendment: amendment } } });
});
