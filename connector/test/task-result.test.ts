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

test("human PR report includes original intent, exact files, review provenance and honest check limitations", () => {
  const result = normalizeTaskResult({ outcome: "completed", summary: "Added export", validation: [{ command: "npm test", status: "passed" }, { command: "browser test", status: "not_run" }] });
  const report = formatTaskReport(result, {
    title: "Export CSV", request: "Workspace admins need monthly CSV reports. @everyone <script>bad</script>",
    files: ["src/export.ts"], commit: "b".repeat(40), baseline: "a".repeat(40),
    review: { baseline: "a".repeat(40), commit: "b".repeat(40), generation: 1, task_digest: "c".repeat(64), verdict: "approve", summary: "No actionable issues found", findings: [], limitations: ["Inspection only"] }
  });
  for (const section of ["Original request", "Agent implementation summary", "Changed files", "Validation", "Independent review", "Human review checklist"]) assert.ok(report.includes(section));
  assert.match(report, /monthly CSV/); assert.match(report, /src\/export\.ts/); assert.match(report, /browser test: not_run/);
  assert.match(report, /Inspection only/); assert.match(report, /bbbbbbbb/);
  assert.doesNotMatch(report, /@everyone|<script>/);
});

test("PR context redacts private source URLs and credentials, and does not claim unperformed review", () => {
  const report = formatTaskReport(normalizeTaskResult({ outcome: "completed" }), {
    request: 'See https://uploads.linear.app/private/image.png?signature=secret and Authorization: Bearer confidentialtoken123', files: [], commit: "a".repeat(40), baseline: "b".repeat(40)
  });
  assert.doesNotMatch(report, /signature=secret|confidentialtoken123/);
  assert.match(report, /not performed/i);
});

test("human PR context separates agent claims from connector-executed validation", () => {
  const result=normalizeTaskResult({outcome:"completed",validation:[{command:"browser check",status:"passed",source:"connector"},{command:"npm test",status:"passed"}],verification_notes:["Everything verified"]});
  const report=formatTaskReport(result,{files:[],commit:"b".repeat(40),baseline:"a".repeat(40),executedChecks:[{command:"npm test",status:"passed"}]});
  assert.match(report,/Connector-executed checks[\s\S]*npm test: passed[\s\S]*Agent-reported checks[\s\S]*browser check: passed/);
  assert.match(report,/Agent-reported checks are claims/);
});
