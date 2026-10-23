export type PublicExecutionEvent =
  | { kind: "message_delta"; text: string }
  | { kind: "plan"; steps: Array<{ step: string; status: string }> }
  | { kind: "usage"; inputTokens: number; outputTokens: number }
  | { kind: "warning"; message: string }
  | { kind: "turn_completed"; status: string };

const bounded = (value: unknown, max: number): string | undefined => typeof value === "string" && value.trim() ? value.slice(0, max) : undefined;
const secretPattern = /\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})\b/g;
const safeText = (value: unknown, max: number): string | undefined => {
  const text = bounded(value, max);
  if (!text) return undefined;
  return text
    .replace(secretPattern, "[redacted]")
    .replace(/(?:\/Users\/[^\s"'`]+|\/home\/[^\s"'`]+|[A-Za-z]:\\Users\\[^\s"'`]+)/g, "[local path]");
};

const secretPrefixes = ["sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"];
const secretCharacters = /^[A-Za-z0-9_-]*$/;

export class StreamingRedactor {
  private carry = "";

  push(value: unknown): string {
    if (typeof value !== "string" || value === "") return "";
    let combined = (this.carry + value).slice(-1_512);
    this.carry = "";
    const searchStart = Math.max(0, combined.length - 260);
    let holdAt = combined.length;
    for (let index = searchStart; index < combined.length; index++) {
      const suffix = combined.slice(index);
      const partialPrefix = secretPrefixes.some(prefix => prefix.startsWith(suffix));
      const activeSecret = secretPrefixes.some(prefix => suffix.startsWith(prefix) && secretCharacters.test(suffix.slice(prefix.length)));
      if (partialPrefix || activeSecret) { holdAt = index; break; }
    }
    if (holdAt < combined.length) {
      this.carry = combined.slice(holdAt);
      combined = combined.slice(0, holdAt);
    }
    return safeText(combined, 1_000) ?? "";
  }

  flush(): string {
    const value = safeText(this.carry, 1_000) ?? "";
    this.carry = "";
    return value;
  }
}

export function publicEventFromNotification(message: any, threadId: string, redactor?: StreamingRedactor): PublicExecutionEvent | undefined {
  const params = message?.params;
  if (!params || params.threadId !== threadId) return undefined;
  switch (message.method) {
    case "item/agentMessage/delta": {
      const text = redactor ? redactor.push(params.delta) : safeText(params.delta, 1_000);
      return text ? { kind: "message_delta", text } : undefined;
    }
    case "turn/plan/updated": {
      if (!Array.isArray(params.plan)) return undefined;
      const steps = params.plan.slice(0, 20).flatMap((entry: any) => {
        const step = safeText(entry?.step, 160);
        const status = bounded(entry?.status, 32);
        return step && status ? [{ step, status }] : [];
      });
      return { kind: "plan", steps };
    }
    case "thread/tokenUsage/updated": {
      const total = params.tokenUsage?.total;
      if (!Number.isFinite(total?.inputTokens) || !Number.isFinite(total?.outputTokens)) return undefined;
      return { kind: "usage", inputTokens: total.inputTokens, outputTokens: total.outputTokens };
    }
    case "warning": {
      const message = safeText(params.message, 300);
      return message ? { kind: "warning", message } : undefined;
    }
    case "turn/completed": {
      const status = bounded(params.turn?.status, 32);
      return status ? { kind: "turn_completed", status } : undefined;
    }
    default: return undefined;
  }
}
