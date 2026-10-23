import { createHash } from "node:crypto";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { AppServerSession } from "./app-server/session.ts";
import { authorizeCommand, authorizeFileChange } from "./app-server/capabilities.ts";
import type { ActivityStage } from "./activity.ts";
import type { PublicExecutionEvent } from "./app-server/events.ts";
import { normalizeTaskResult, taskResultSchema, type TaskResult } from "./task-result.ts";

export class RepeatedFailureError extends Error {
  readonly fingerprint: string;
  constructor(fingerprint: string) { super("Codex repeated the same failed command three times."); this.fingerprint = fingerprint; }
}
export class CodexBlockedError extends Error {
  readonly result: TaskResult;
  constructor(result: TaskResult | string) {
    const normalized = normalizeTaskResult(typeof result === "string" ? { outcome: "blocked", summary: result } : result);
    super(normalized.blocker?.message ?? normalized.summary);
    this.result = normalized;
  }
}
export class CodexPolicyError extends Error {}

export class CodexSession {
  readonly child: ChildProcessWithoutNullStreams;
  readonly session: AppServerSession;
  private readonly workspace?: string;
  private commandFailures = new Map<string, number>();
  private repeatedFailure?: RepeatedFailureError;

  constructor(child: ChildProcessWithoutNullStreams, workspace?: string, existingSession?: AppServerSession) {
    this.child = child;
    this.workspace = workspace;
    this.session = existingSession ?? new AppServerSession(child, {
      // The app-server sandbox is limited to the task workspace; its approval requests
      // therefore represent routine operations inside the already-authorized checkout.
      authorizeCommand: () => true,
      authorizeFileChange: params => {
        const paths = [params?.grantRoot, params?.filePath, params?.path].filter((value): value is string => typeof value === "string");
        return paths.every(path => !path.startsWith("/") || Boolean(this.workspace && (path === this.workspace || path.startsWith(this.workspace + "/"))));
      }
    });
    this.session.on("notification", message => this.inspectCommand(message));
  }

  static start(binary: string, workspace: string, allowedHosts?: string[]): CodexSession {
    const session = AppServerSession.open({ binary, cwd: workspace, allowedHosts });
    return new CodexSession(session.child, workspace, session);
  }

  initialize(): Promise<void> { return this.session.initialize(); }
  authenticated(): Promise<boolean> { return this.session.authenticated(); }

  async run(workspace: string, prompt: string, model?: string, signal?: AbortSignal, onProgress?: (stage: ActivityStage) => Promise<void>, onEvent?: (event: PublicExecutionEvent) => Promise<void>, policy?: any, recovery: { threadId?: string; onThreadStarted?: (threadId: string) => Promise<void>; onUserInput?: (params: any) => Promise<unknown> } = {}): Promise<TaskResult> {
    if (signal?.aborted) throw new Error("Task stopped before lease expiration.");
    if (policy && policy.valid === false) throw new CodexPolicyError("Configured model is not supported by this executor deployment.");
    const selectedModel = typeof policy?.model === "string" ? policy.model : model;
    const allowedHosts = new Set<string>(Array.isArray(policy?.network?.allowed_hosts) ? policy.network.allowed_hosts.filter((host: unknown): host is string => typeof host === "string").map((host: string) => host.toLowerCase()) : []);
    this.session.configureRequestHandlers({
      authorizeCommand: params => authorizeCommand(workspace, [...allowedHosts], params),
      authorizeFileChange: params => authorizeFileChange(workspace, params),
      ...(recovery.onUserInput ? { requestUserInput: params => recovery.onUserInput?.(params) } : {})
    });
    const threadOptions = { cwd: workspace, approvalPolicy: "never", permissions: "dev-orchestrator", model: selectedModel };
    const threadId = recovery.threadId
      ? await this.session.resumeThread(recovery.threadId, threadOptions)
      : await this.session.startThread(threadOptions);
    await recovery.onThreadStarted?.(threadId);
    const abort = () => this.stop();
    signal?.addEventListener("abort", abort, { once: true });
    let bufferedDelta = "";
    let deltaTimer: NodeJS.Timeout | undefined;
    let eventQueue = Promise.resolve();
    const enqueue = (event: PublicExecutionEvent) => {
      eventQueue = eventQueue.then(() => onEvent?.(event));
      void eventQueue.catch(() => {});
    };
    const flushDelta = () => {
      if (deltaTimer) clearTimeout(deltaTimer);
      deltaTimer = undefined;
      const text = bufferedDelta;
      bufferedDelta = "";
      if (text) enqueue({ kind: "message_delta", text });
      return eventQueue;
    };
    const onPublicEvent = (event: PublicExecutionEvent) => {
      if (event.kind === "message_delta") {
        bufferedDelta = (bufferedDelta + event.text).slice(-1_000);
        if (!deltaTimer) {
          deltaTimer = setTimeout(() => { void flushDelta().catch(() => {}); }, 700);
          deltaTimer.unref();
        }
      } else {
        void flushDelta().catch(() => {});
        enqueue(event);
      }
    };
    this.session.on("event", onPublicEvent);
    try {
      const completed = this.session.runTurn(prompt, {
        cwd: workspace,
        effort: typeof policy?.effort === "string" ? policy.effort : undefined,
        outputSchema: taskResultSchema,
        onProgress
      });
      const repeated = new Promise<never>((_, reject) => {
        const listener = (error: RepeatedFailureError) => { this.session.off("repeatedFailure", listener); reject(error); };
        this.session.on("repeatedFailure", listener);
        completed.finally(() => this.session.off("repeatedFailure", listener)).catch(() => {});
      });
      const result = await Promise.race([completed, repeated]);
      await flushDelta();
      await eventQueue;
      const task = normalizeTaskResult(result.result ?? { outcome: result.outcome });
      if (task.outcome === "blocked") throw new CodexBlockedError(task);
      return task;
    } finally {
      if (deltaTimer) clearTimeout(deltaTimer);
      this.session.off("event", onPublicEvent);
      signal?.removeEventListener("abort", abort);
    }
  }

  stop(): void { this.session.close(); }

  private inspectCommand(message: any): void {
    const item = message?.params?.item;
    if (message?.method !== "item/completed" || item?.type !== "commandExecution" || !(typeof item.exitCode === "number" && item.exitCode !== 0 || item.status === "failed")) return;
    const command = String(item.command ?? "");
    const wrapped = command.trim().match(/^(?:\/[^\s]+\/)?(?:bash|zsh|sh)\s+-lc\s+(['"])([\s\S]*)\1$/);
    const probe = (wrapped?.[2] ?? command).trim();
    const unquoted = probe.replace(/"[^"\n]*"|'[^'\n]*'/g, "");
    const expectedMiss = item.exitCode === 1 && /^(?:rg|grep|test|\[)(?:\s|$)/.test(probe) && !/[;&|]/.test(unquoted);
    if (expectedMiss) return;
    const detail = (command + ":" + String(item.exitCode) + ":" + String(item.aggregatedOutput ?? ""))
      .replace(/\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi, "<id>")
      .replace(/\b\d+(?:\.\d+)?\s*(?:ms|s|seconds)\b/g, "<duration>");
    const fingerprint = createHash("sha256").update(detail).digest("hex");
    const count = (this.commandFailures.get(fingerprint) ?? 0) + 1;
    this.commandFailures.set(fingerprint, count);
    if (count >= 3) {
      this.repeatedFailure = new RepeatedFailureError(fingerprint);
      this.session.emit("repeatedFailure", this.repeatedFailure);
    }
  }
}
