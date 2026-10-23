import test from "node:test";
import assert from "node:assert/strict";
import { publicEventFromNotification, StreamingRedactor } from "../../src/app-server/events.ts";

test("agent message deltas are surfaced while reasoning and command output stay private", () => {
  assert.deepEqual(publicEventFromNotification({
    method: "item/agentMessage/delta",
    params: { threadId: "thread-1", delta: "I will inspect the changed files." }
  }, "thread-1"), { kind: "message_delta", text: "I will inspect the changed files." });
  assert.equal(publicEventFromNotification({
    method: "item/reasoning/textDelta", params: { threadId: "thread-1", delta: "private" }
  }, "thread-1"), undefined);
  assert.equal(publicEventFromNotification({
    method: "item/commandExecution/outputDelta", params: { threadId: "thread-1", delta: "secret output" }
  }, "thread-1"), undefined);
});

test("plan, usage, warning, and turn-completion events are bounded and scoped to the active thread", () => {
  assert.deepEqual(publicEventFromNotification({
    method: "turn/plan/updated",
    params: { threadId: "thread-1", plan: [{ step: "Add a test", status: "inProgress" }] }
  }, "thread-1"), { kind: "plan", steps: [{ step: "Add a test", status: "inProgress" }] });
  assert.deepEqual(publicEventFromNotification({
    method: "thread/tokenUsage/updated",
    params: { threadId: "thread-1", tokenUsage: { total: { inputTokens: 50, outputTokens: 12 } } }
  }, "thread-1"), { kind: "usage", inputTokens: 50, outputTokens: 12 });
  assert.deepEqual(publicEventFromNotification({
    method: "warning", params: { threadId: "thread-1", message: "Model fallback occurred." }
  }, "thread-1"), { kind: "warning", message: "Model fallback occurred." });
  assert.equal(publicEventFromNotification({
    method: "turn/completed", params: { threadId: "other", turn: { status: "completed" } }
  }, "thread-1"), undefined);
});

test("public agent updates redact credentials and local filesystem paths", () => {
  assert.deepEqual(publicEventFromNotification({
    method: "item/agentMessage/delta",
    params: { threadId: "thread-1", delta: "Updated /Users/juan/project with ghp_123456789012345678901234567890" }
  }, "thread-1"), { kind: "message_delta", text: "Updated [local path] with [redacted]" });
});

test("streaming redaction retains split credential fragments until they are safe", () => {
  const redactor = new StreamingRedactor();
  assert.equal(redactor.push("Working with gh"), "Working with ");
  assert.equal(redactor.push("p_1234567890"), "");
  assert.equal(redactor.push("12345678901234567890 finished"), "[redacted] finished");
  assert.equal(redactor.flush(), "");
});
