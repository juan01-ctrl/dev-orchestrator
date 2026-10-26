import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { AppServerClient } from "./client.ts";
import { publicEventFromNotification, StreamingRedactor, type PublicExecutionEvent } from "./events.ts";
import { resolveServerRequest, type RequestHandlers } from "./requests.ts";
import { activityForNotification, type ActivityStage } from "../activity.ts";
import type { TaskResult } from "../task-result.ts";
import type { SandboxCommandResult } from "../environment.ts";
import { cleanGitEnv } from "../process.ts";

type ThreadOptions = { cwd: string; permissions?: string; model?: string; approvalPolicy?: string };
type SessionOptions = { binary: string; cwd: string; requestHandlers?: RequestHandlers; model?: string; allowedHosts?: string[]; readOnly?: boolean };
type TurnResult = { status: string; outcome?: string; result?: TaskResult };

export function buildAppServerArgs(allowedHosts: string[] = [], readOnly = false): string[] {
  const args = ["app-server", "--listen", "stdio://",
    "-c", 'default_permissions="dev-orchestrator"',
    "-c", 'permissions.dev-orchestrator.extends=":workspace"',
    "-c", readOnly ? 'permissions.dev-orchestrator.filesystem={":workspace_roots"={"."="read",".git"="read",".agents"="read",".codex"="read"}}' : 'permissions.dev-orchestrator.filesystem={":workspace_roots"={"."="write",".git"="read",".agents"="write",".codex"="read"}}',
    "-c", "permissions.dev-orchestrator.network.enabled=false"];
  const hosts = [...new Set(allowedHosts)];
  if (hosts.some(host => !/^(?=.{1,253}$)[a-z0-9]+(?:[.-][a-z0-9]+)*$/i.test(host))) throw new Error("Invalid execution network allowlist.");
  if (hosts.length) args.push("-c", "features.network_proxy=true", "-c", "permissions.dev-orchestrator.network.enabled=true", "-c", `permissions.dev-orchestrator.network.domains={${hosts.map(host => `${JSON.stringify(host)}="allow"`).join(",")}}`);
  return args;
}

export class AppServerSession extends EventEmitter {
  readonly client: AppServerClient;
  readonly child: ChildProcessWithoutNullStreams;
  private initialized = false;
  private threadId?: string;
  private activeTurn?: { threadId: string; resolve: (value: TurnResult) => void; reject: (error: Error) => void; outcome?: string; result?: TaskResult };
  private progress?: (stage: ActivityStage) => Promise<void>;
  private progressQueue = Promise.resolve();
  private lastStage?: ActivityStage;
  private handlers: RequestHandlers;
  private publicRedactor = new StreamingRedactor();

  constructor(child: ChildProcessWithoutNullStreams, requestHandlers: RequestHandlers = {}) {
    super();
    this.child = child;
    this.handlers = requestHandlers;
    this.client = new AppServerClient(child);
    this.client.on("notification", message => this.onNotification(message));
    this.client.on("serverRequest", request => { void resolveServerRequest(this.handlers, [request]).then(async ([resolution]) => {
      if (resolution?.error) await this.client.reject(resolution.id, resolution.error.code, resolution.error.message);
      else await this.client.respond(resolution!.id, resolution?.result);
    }).catch(() => this.emit("warning", new Error("Unable to resolve app-server request."))); });
    this.client.on("close", error => { if (this.activeTurn) this.activeTurn.reject(error ?? new Error("Codex app-server stopped.")); });
  }

  static open(options: SessionOptions): AppServerSession {
    const allowed = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"];
    const env = Object.fromEntries(allowed.filter(key => process.env[key] !== undefined).map(key => [key, process.env[key]]));
    env.GIT_OPTIONAL_LOCKS = "0";
    if(options.readOnly)Object.assign(env,cleanGitEnv(),{GIT_ATTR_NOSYSTEM:"1",GIT_CONFIG_COUNT:"2",GIT_CONFIG_KEY_0:"core.hooksPath",GIT_CONFIG_VALUE_0:"/dev/null",GIT_CONFIG_KEY_1:"core.attributesFile",GIT_CONFIG_VALUE_1:"/dev/null"});
    const args = buildAppServerArgs(options.allowedHosts, options.readOnly);
    const session = new AppServerSession(spawn(options.binary, args, { cwd: options.cwd, env, detached: true, stdio: ["pipe", "pipe", "pipe"] }), options.requestHandlers);
    session.defaultModel = options.model;
    return session;
  }

  private defaultModel?: string;

  async initialize(): Promise<void> {
    if (this.initialized) return;
    await this.client.request("initialize", { clientInfo: { name: "dev_orchestrator", title: "Dev Orchestrator", version: "0.1.0" }, capabilities: { experimentalApi: true } });
    this.client.notify("initialized", {});
    this.initialized = true;
  }

  configureRequestHandlers(handlers: RequestHandlers): void { this.handlers = handlers; }

  async exec(command: string[], cwd: string, signal: AbortSignal, timeoutMs = 120_000): Promise<SandboxCommandResult> {
    if (signal.aborted) throw new Error("Task stopped before environment execution.");
    const stop = () => this.close();
    signal.addEventListener("abort", stop, { once: true });
    try {
      const result = await this.client.request("command/exec", {
        command, cwd, permissionProfile: "dev-orchestrator", timeoutMs, outputBytesCap: 8_192,
        env: { npm_config_cache: cwd + "/.dev-orchestrator-cache/npm", npm_config_userconfig: "/dev/null", GIT_OPTIONAL_LOCKS: "0", CI: "true" }
      }, timeoutMs + 5_000);
      if (!Number.isInteger(result?.exitCode)) throw new Error("Codex returned no environment command status.");
      return { exitCode: result.exitCode, stdout: String(result.stdout ?? "").slice(-8_192), stderr: String(result.stderr ?? "").slice(-8_192) };
    } finally { signal.removeEventListener("abort", stop); }
  }

  async authenticated(): Promise<boolean> {
    const result = await this.client.request("account/read", { refreshToken: false });
    return result?.account?.type === "chatgpt";
  }

  async permissionProfiles(): Promise<any[]> {
    const result = await this.client.request("permissionProfile/list", {});
    return Array.isArray(result?.data) ? result.data : [];
  }

  async startThread(options: ThreadOptions): Promise<string> {
    await this.initialize();
    await this.permissionProfiles();
    const result = await this.client.request("thread/start", { cwd: options.cwd, approvalPolicy: options.approvalPolicy ?? "never", permissions: options.permissions ?? "dev-orchestrator", ...(options.model ?? this.defaultModel ? { model: options.model ?? this.defaultModel } : {}) });
    const id = result?.thread?.id;
    if (typeof id !== "string" || !id) throw new Error("Codex returned no task thread.");
    this.threadId = id;
    return id;
  }

  async resumeThread(threadId: string, options: ThreadOptions): Promise<string> {
    await this.initialize();
    const result = await this.client.request("thread/resume", { threadId, cwd: options.cwd, approvalPolicy: options.approvalPolicy ?? "never", permissions: options.permissions ?? "dev-orchestrator", ...(options.model ?? this.defaultModel ? { model: options.model ?? this.defaultModel } : {}) });
    const id = result?.thread?.id;
    if (id !== threadId) throw new Error("Codex resumed a different task thread.");
    this.threadId = threadId;
    return threadId;
  }

  runTurn(prompt: string, options: { cwd?: string; outputSchema?: unknown; effort?: string; imagePaths?: string[]; onProgress?: (stage: ActivityStage) => Promise<void> } = {}): Promise<TurnResult> {
    if (!this.threadId) return Promise.reject(new Error("Start or resume a Codex thread before running a turn."));
    if (this.activeTurn) return Promise.reject(new Error("A Codex turn is already active in this session."));
    this.progress = options.onProgress;
    this.publicRedactor = new StreamingRedactor();
    this.lastStage = undefined;
    const threadId = this.threadId;
    const completed = new Promise<TurnResult>((resolve, reject) => { this.activeTurn = { threadId, resolve, reject }; });
    const input = [{ type: "text", text: prompt }, ...(options.imagePaths ?? []).map(path => ({ type: "localImage", path, detail: "original" }))];
    void this.client.request("turn/start", { threadId, ...(options.cwd ? { cwd: options.cwd } : {}), approvalPolicy: "never", permissions: "dev-orchestrator", ...(options.effort ? { effort: options.effort } : {}), input, ...(options.outputSchema ? { outputSchema: options.outputSchema } : {}) }).catch(error => this.activeTurn?.reject(error));
    return completed.finally(() => { this.activeTurn = undefined; this.progress = undefined; });
  }

  respond(id: string | number, result: unknown): Promise<void> { return this.client.respond(id, result); }
  close(): void { this.client.close(); }

  private onNotification(message: any): void {
    const params = message?.params;
    if (!params || params.threadId !== this.threadId) return;
    this.emit("notification", message);
    if (message.method === "turn/completed") {
      const remainder = this.publicRedactor.flush();
      if (remainder) this.emit("event", { kind: "message_delta", text: remainder } satisfies PublicExecutionEvent);
    }
    const publicEvent = publicEventFromNotification(message, this.threadId!, this.publicRedactor);
    if (publicEvent) this.emit("event", publicEvent satisfies PublicExecutionEvent);
    const stage = activityForNotification(message);
    if (stage && stage !== this.lastStage) {
      this.lastStage = stage;
      this.progressQueue = this.progressQueue.then(() => this.progress?.(stage));
      void this.progressQueue.catch(error => this.emit("warning", error));
    }
    if (message.method === "item/completed" && params.item?.type === "agentMessage") {
      try { const result = JSON.parse(params.item.text); if (["completed", "blocked"].includes(result?.outcome) && this.activeTurn) { this.activeTurn.outcome = result.outcome; if (typeof result.summary === "string" || result.blocker) this.activeTurn.result = result; } }
      catch { /* structured outcome may arrive in a later assistant message */ }
    }
    const activeTurn = this.activeTurn;
    if (message.method === "turn/completed" && activeTurn && activeTurn.threadId === params.threadId) {
      const status = params.turn?.status;
      const outcome = activeTurn.outcome;
      void this.progressQueue.then(() => {
        if (status === "completed" && ["completed", "blocked"].includes(outcome ?? "")) activeTurn.resolve({ status, outcome, ...(activeTurn.result ? { result: activeTurn.result } : {}) });
        else activeTurn.reject(new Error("Codex turn did not complete."));
      }, error => activeTurn.reject(error instanceof Error ? error : new Error("Progress delivery failed.")));
    }
  }
}
