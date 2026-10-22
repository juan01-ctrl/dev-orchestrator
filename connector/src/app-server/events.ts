export type PublicExecutionEvent =
  | { kind: "message_delta"; text: string }
  | { kind: "plan"; steps: Array<{ step: string; status: string }> }
  | { kind: "usage"; inputTokens: number; outputTokens: number }
  | { kind: "warning"; message: string }
  | { kind: "turn_completed"; status: string };

const bounded = (value: unknown, max: number): string | undefined => typeof value === "string" && value.trim() ? value.slice(0, max) : undefined;

export function publicEventFromNotification(message: any, threadId: string): PublicExecutionEvent | undefined {
  const params = message?.params;
  if (!params || params.threadId !== threadId) return undefined;
  switch (message.method) {
    case "item/agentMessage/delta": {
      const text = bounded(params.delta, 1_000);
      return text ? { kind: "message_delta", text } : undefined;
    }
    case "turn/plan/updated": {
      if (!Array.isArray(params.plan)) return undefined;
      const steps = params.plan.slice(0, 20).flatMap((entry: any) => {
        const step = bounded(entry?.step, 160);
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
      const message = bounded(params.message, 300);
      return message ? { kind: "warning", message } : undefined;
    }
    case "turn/completed": {
      const status = bounded(params.turn?.status, 32);
      return status ? { kind: "turn_completed", status } : undefined;
    }
    default: return undefined;
  }
}
