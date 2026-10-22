import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { AppServerClient } from "./client.ts";
import { publicEventFromNotification, type PublicExecutionEvent } from "./events.ts";
import { resolveServerRequest, type RequestHandlers } from "./requests.ts";
import { activityForNotification, type ActivityStage } from "../activity.ts";

type ThreadOptions = { cwd: string; permissions?: string; model?: string; approvalPolicy?: string };
type SessionOptions = { binary: string; cwd: string; requestHandlers?: RequestHandlers; model?: string };

export class AppServerSession extends EventEmitter {
  readonly client: AppServerClient;
  readonly child: ChildProcessWithoutNullStreams;
  private initialized = false;
  private threadId?: string;
  private activeTurn?: { threadId: string; resolve: (value: { status: string; outcome?: string }) => void; reject: (error: Error) => void; outcome?: string };
  private progress?: (stage: ActivityStage) => Promise<void>;
  private progressQueue = Promise.resolve();
  private lastStage?: ActivityStage;
  private handlers: RequestHandlers;

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
    const args = ["app-server", "--listen", "stdio://",
      "-c", 'permissions.dev-orchestrator.extends=":workspace"',
      "-c", 'permissions.dev-orchestrator.filesystem={":workspace_roots"={"."="write",".git"="write",".agents"="write",".codex"="read",".aws"="read"}}',
      "-c", "permissions.dev-orchestrator.network.enabled=false"];
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

  runTurn(prompt: string, options: { cwd?: string; outputSchema?: unknown; onProgress?: (stage: ActivityStage) => Promise<void> } = {}): Promise<{ status: string; outcome?: string }> {
    if (!this.threadId) return Promise.reject(new Error("Start or resume a Codex thread before running a turn."));
    if (this.activeTurn) return Promise.reject(new Error("A Codex turn is already active in this session."));
    this.progress = options.onProgress;
    this.lastStage = undefined;
    const threadId = this.threadId;
    const completed = new Promise<{ status: string; outcome?: string }>((resolve, reject) => { this.activeTurn = { threadId, resolve, reject }; });
    void this.client.request("turn/start", { threadId, ...(options.cwd ? { cwd: options.cwd } : {}), approvalPolicy: "never", permissions: "dev-orchestrator", input: [{ type: "text", text: prompt }], ...(options.outputSchema ? { outputSchema: options.outputSchema } : {}) }).catch(error => this.activeTurn?.reject(error));
    return completed.finally(() => { this.activeTurn = undefined; this.progress = undefined; });
  }

  respond(id: string | number, result: unknown): Promise<void> { return this.client.respond(id, result); }
  close(): void { this.client.close(); }

  private onNotification(message: any): void {
    const params = message?.params;
    if (!params || params.threadId !== this.threadId) return;
    this.emit("notification", message);
    const publicEvent = publicEventFromNotification(message, this.threadId!);
    if (publicEvent) this.emit("event", publicEvent satisfies PublicExecutionEvent);
    const stage = activityForNotification(message);
    if (stage && stage !== this.lastStage) {
      this.lastStage = stage;
      this.progressQueue = this.progressQueue.then(() => this.progress?.(stage));
      void this.progressQueue.catch(error => this.emit("warning", error));
    }
    if (message.method === "item/completed" && params.item?.type === "agentMessage") {
      try { const result = JSON.parse(params.item.text); if (["completed", "blocked"].includes(result?.outcome) && this.activeTurn) this.activeTurn.outcome = result.outcome; }
      catch { /* structured outcome may arrive in a later assistant message */ }
    }
    const activeTurn = this.activeTurn;
    if (message.method === "turn/completed" && activeTurn && activeTurn.threadId === params.threadId) {
      const status = params.turn?.status;
      const outcome = activeTurn.outcome;
      void this.progressQueue.then(() => {
        if (status === "completed" && outcome === "completed") activeTurn.resolve({ status, outcome });
        else if (outcome === "blocked") activeTurn.reject(new Error("Essential context is missing; the task is blocked."));
        else activeTurn.reject(new Error("Codex turn did not complete."));
      }, error => activeTurn.reject(error instanceof Error ? error : new Error("Progress delivery failed.")));
    }
  }
}
