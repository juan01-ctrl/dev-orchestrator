export type CheckResult = { command: string; status: "passed" | "failed" | "not_run" };
export type BlockerCategory = "missing_context" | "environment_setup_failed" | "validation_failed" | "authentication_required" | "network_unavailable" | "execution_failed" | "execution_timeout" | "recovery_exhausted";
export type TaskResult = { outcome: "completed" | "blocked"; summary: string; validation: CheckResult[]; changes?: string[]; risks?: string[]; verification_notes?: string[]; blocker: { category: BlockerCategory; message: string; question: string } | null };
const categories: BlockerCategory[] = ["missing_context", "environment_setup_failed", "validation_failed", "authentication_required", "network_unavailable", "execution_failed", "execution_timeout", "recovery_exhausted"];

export function safeText(value: unknown, limit = 1_000): string {
  return (typeof value === "string" ? value : "")
    .replace(/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})\b/g, "[redacted]")
    .replace(/https?:\/\/[^\s/@]+:[^\s/@]+@[^\s]+/g, "[redacted URL]")
    .replace(/(?:\/Users\/[^\s"'`]+|\/home\/[^\s"'`]+|[A-Za-z]:\\Users\\[^\s"'`]+)/g, "[local path]")
    .slice(0, limit);
}

export function normalizeTaskResult(value: unknown): TaskResult {
  const result = value as Partial<TaskResult> | null;
  if (!result || !["completed", "blocked"].includes(result.outcome ?? "")) throw new Error("Codex returned no valid task outcome.");
  const validation: CheckResult[] = Array.isArray(result.validation) ? result.validation.slice(0, 12).flatMap(check =>
    check && typeof check.command === "string" && ["passed", "failed", "not_run"].includes(check.status)
      ? [{ command: safeText(check.command, 200), status: check.status }] : []) : [];
  const blocked = result.outcome === "blocked";
  const question = safeText(result.blocker?.question, 600).trim();
  let category = categories.includes(result.blocker?.category as BlockerCategory) ? result.blocker!.category : "execution_failed";
  if (category === "missing_context" && !question) category = "execution_failed";
  return {
    outcome: blocked ? "blocked" : "completed",
    summary: safeText(result.summary, 1_000).trim() || (blocked ? "The task could not complete." : "The requested changes are ready for review."),
    validation,
    ...Object.fromEntries(["changes", "risks", "verification_notes"].filter(key => Array.isArray((result as any)[key])).map(key => [key, (result as any)[key].slice(0, 8).filter((v: unknown) => typeof v === "string").map((v: string) => safeText(v, 500))])),
    blocker: blocked ? { category, message: safeText(result.blocker?.message, 600).trim() || "The agent stopped without a specific blocker. Review its execution activity.", question } : null
  };
}

export type PRContext = { title?: string; request?: string; adjustment?: string; runURL?: string; files: string[]; commit: string; baseline: string; review?: import("./reviewer.ts").CandidateReview; executedChecks?:CheckResult[] };

function markdown(value: unknown, limit = 8000): string {
  return safeText(value, limit)
    .replace(/https?:\/\/(?:uploads\.linear\.app|files\.slack\.com)\/[^\s)]+/gi, "[private reference]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+/-]{8,}/gi, "Bearer [redacted]")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/([\\`*_[\]#|])/g, "\\$1").replace(/@/g, "@\u200b");
}

export function formatTaskReport(result: TaskResult, context?: PRContext): string {
  const checks = result.validation.length ? result.validation.map(check => `- ${markdown(check.command, 200)}: ${check.status}`).join("\n") : "No project checks were recorded.";
  if (!context) return `## Summary\n\n${markdown(result.summary)}\n\n## Validation\n\n${checks}`;
  const list = (items: string[] | undefined, fallback: string) => items?.length ? items.map(item => `- ${markdown(item, 500)}`).join("\n") : fallback;
  const review = context.review;
  const executed=context.executedChecks??[], executedNames=new Set(executed.map(check=>check.command));
  const checkList=(items:CheckResult[])=>items.length?items.map(check=>`- ${markdown(check.command,200)}: ${check.status}`).join("\n"):"None recorded.";
  return [
    "## Original request and purpose", markdown(context.title ?? "Development task", 240),
    markdown(context.request ?? "No original request supplied."),
    context.adjustment ? "### Approved adjustment\n\n" + markdown(context.adjustment, 8000) : "",
    "## Agent implementation summary", markdown(result.summary),
    list(result.changes, "No additional implementation rationale was supplied; inspect the diff against the request."),
    "## Changed files", context.files.slice(0, 100).map(file => `- ${markdown(file, 400)}`).join("\n") || "No net changed files relative to the original baseline.",
    context.files.length > 100 ? `${context.files.length - 100} additional files omitted from this summary; inspect Files changed.` : "",
    "## Validation", "### Connector-executed checks",checkList(executed),
    "### Agent-reported checks",checkList(result.validation.filter(check=>!executedNames.has(check.command))),
    "Agent-reported checks are claims from the implementation agent, not independently observed connector results. Not-run checks remain unverified.",
    "### Agent verification notes",list(result.verification_notes,"No additional verification notes supplied."),
    "## Independent review", review ? `Verdict: **${review.verdict}**\n\n${markdown(review.summary, 1500)}\n\n` +
      (review.findings.length ? review.findings.map(f => `- ${f.severity}: ${markdown(f.path, 400)}:${f.line} — ${markdown(f.description)} Evidence: ${markdown(f.evidence)}`).join("\n") : "No actionable findings reported.") +
      "\n\n" + list(review.limitations, "Inspection only; no independent build/test execution claimed.") : "Not performed for this legacy snapshot. This is not an independent approval.",
    "## Risks and remaining verification", list(result.risks, "The agent supplied no additional risks. This does not establish that the change is risk-free."),
    "Review approval does not override failed checks or establish visual fidelity, deployment success, or complete correctness.",
    "## Provenance", `Original baseline: ${context.baseline}\n\nCandidate commit: ${context.commit}`,
    context.runURL ? `Run: ${markdown(context.runURL, 300)}` : "",
    "The implementation summary describes the agent's work. The trusted connector handles commits, publication and PR identity verification afterward.",
    "## Human review checklist", "- [ ] Compare the diff with the original request and approved adjustment.\n- [ ] Check behavior and edge cases, especially unexecuted checks and review limitations.\n- [ ] Inspect CI results and any remaining risks.\n- [ ] Decide whether to merge; no automatic merge or deployment is performed."
  ].filter(Boolean).join("\n\n").slice(0, 60_000);
}

export const taskResultSchema = {
  type: "object", additionalProperties: false, required: ["outcome", "summary", "validation", "blocker", "changes", "risks", "verification_notes"],
  properties: {
    outcome: { type: "string", enum: ["completed", "blocked"] }, summary: { type: "string" },
    changes: { type: "array", items: { type: "string" } }, risks: { type: "array", items: { type: "string" } }, verification_notes: { type: "array", items: { type: "string" } },
    validation: { type: "array", items: { type: "object", additionalProperties: false, required: ["command", "status"], properties: { command: { type: "string" }, status: { type: "string", enum: ["passed", "failed", "not_run"] } } } },
    blocker: { anyOf: [{ type: "null" }, { type: "object", additionalProperties: false, required: ["category", "message", "question"], properties: { category: { type: "string", enum: categories }, message: { type: "string" }, question: { type: "string" } } }] }
  }
};
