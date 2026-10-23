import test from "node:test";
import assert from "node:assert/strict";
import { normalizeTaskResult, formatTaskReport } from "../src/task-result.ts";

test("a blocked result needs an actual question before it is classified as missing context", () => {
  const result = normalizeTaskResult({ outcome: "blocked", summary: "Cannot run checks", blocker: { category: "missing_context", message: "Astro is not installed", question: "" } });
  assert.equal(result.blocker?.category, "execution_failed");
  const question = normalizeTaskResult({ outcome: "blocked", summary: "Choose the payment account", blocker: { category: "missing_context", message: "Two accounts exist", question: "Which account should receive payments?" } });
  assert.equal(question.blocker?.category, "missing_context");
  assert.equal(question.blocker?.question, "Which account should receive payments?");
  assert.equal(normalizeTaskResult({ outcome: "blocked" }).blocker?.category, "execution_failed");
});

test("structured results are bounded, redact credentials and retain useful checks in the report", () => {
  const result = normalizeTaskResult({ outcome: "completed", summary: "Added the popup ghp_123456789012345678901234567890", validation: [{ command: "npm run check", status: "passed" }, { command: "npm run build", status: "not_run" }] });
  const report = formatTaskReport(result);
  assert.match(report, /Added the popup/);
  assert.match(report, /npm run check: passed/);
  assert.match(report, /npm run build: not_run/);
  assert.doesNotMatch(report, /ghp_/);
  assert.throws(() => normalizeTaskResult({ outcome: "maybe" }), /outcome/i);
});
