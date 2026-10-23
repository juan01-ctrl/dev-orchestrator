export type CheckResult = { command: string; status: "passed" | "failed" | "not_run" };
export type BlockerCategory = "missing_context" | "environment_setup_failed" | "validation_failed" | "authentication_required" | "network_unavailable" | "execution_failed" | "execution_timeout" | "recovery_exhausted";
export type TaskResult = { outcome: "completed" | "blocked"; summary: string; validation: CheckResult[]; blocker: { category: BlockerCategory; message: string; question: string } | null };
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
    blocker: blocked ? { category, message: safeText(result.blocker?.message, 600).trim() || "The agent stopped without a specific blocker. Review its execution activity.", question } : null
  };
}

export function formatTaskReport(result: TaskResult): string {
  const checks = result.validation.length ? result.validation.map(check => `- ${check.command}: ${check.status}`).join("\n") : "No project checks were recorded.";
  return `## Summary\n\n${result.summary}\n\n## Validation\n\n${checks}`;
}

export const taskResultSchema = {
  type: "object", additionalProperties: false, required: ["outcome", "summary", "validation", "blocker"],
  properties: {
    outcome: { type: "string", enum: ["completed", "blocked"] }, summary: { type: "string" },
    validation: { type: "array", items: { type: "object", additionalProperties: false, required: ["command", "status"], properties: { command: { type: "string" }, status: { type: "string", enum: ["passed", "failed", "not_run"] } } } },
    blocker: { anyOf: [{ type: "null" }, { type: "object", additionalProperties: false, required: ["category", "message", "question"], properties: { category: { type: "string", enum: categories }, message: { type: "string" }, question: { type: "string" } } }] }
  }
};
