import { EventEmitter } from "node:events";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { stopProcess } from "../process.ts";

type Pending = { resolve: (value: any) => void; reject: (error: Error) => void; timer: NodeJS.Timeout };

export class AppServerClient extends EventEmitter {
  readonly child: ChildProcessWithoutNullStreams;
  private readonly requestTimeoutMs: number;
  private pending = new Map<string | number, Pending>();
  private nextId = 0;
  private buffer = "";
  private closed = false;
  private stderr = "";
  private failure?: Error;

  constructor(child: ChildProcessWithoutNullStreams, requestTimeoutMs = 30_000) {
    super();
    this.child = child;
    this.requestTimeoutMs = requestTimeoutMs;
    child.stdout.on("data", chunk => this.consume(String(chunk)));
    child.stderr.on("data", chunk => {
      this.stderr = (this.stderr + String(chunk)).slice(-8_192);
    });
    child.stdin.on("error", () => this.fail(new Error("Codex app-server transport closed.")));
    child.on("error", (error: NodeJS.ErrnoException) => {
      const executable = error.path ?? "codex";
      const code = error.code ?? "unknown error";
      this.fail(new Error(`Codex executable ${executable} could not start (${code}). Check that it is installed and available in the connector's PATH.`));
    });
    child.on("close", code => this.fail(new Error(code === 0 ? "Codex app-server stopped." : "Codex app-server exited unexpectedly.")));
  }

  request(method: string, params: unknown = {}): Promise<any> {
    if (this.closed) return Promise.reject(this.failure ?? new Error("Codex app-server is closed."));
    return new Promise((resolve, reject) => {
      const id = ++this.nextId;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        const error = new Error("Codex app-server request timed out.");
        reject(error);
        this.close(error);
      }, this.requestTimeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      if (!this.write({ id, method, params })) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(this.failure ?? new Error("Codex app-server transport closed."));
      }
    });
  }

  notify(method: string, params: unknown = {}): void { this.write({ method, params }); }

  respond(id: string | number, result: unknown): Promise<void> {
    if (!this.write({ id, result })) return Promise.reject(this.failure ?? new Error("Codex app-server transport closed."));
    return Promise.resolve();
  }

  reject(id: string | number, code: number, message: string): Promise<void> {
    if (!this.write({ id, error: { code, message } })) return Promise.reject(this.failure ?? new Error("Codex app-server transport closed."));
    return Promise.resolve();
  }

  isClosed(): boolean { return this.closed; }

  close(error?: Error): void {
    if (this.closed) return;
    this.closed = true;
    this.failure = error;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error ?? new Error("Codex app-server is closed."));
    }
    this.pending.clear();
    stopProcess(this.child);
    this.emit("close", error);
  }

  private write(message: unknown): boolean {
    if (this.closed || this.child.stdin.destroyed || !this.child.stdin.writable) return false;
    try { this.child.stdin.write(JSON.stringify(message) + "\n"); return true; }
    catch { this.fail(new Error("Codex app-server transport closed.")); return false; }
  }

  private consume(chunk: string): void {
    this.buffer += chunk;
    if (this.buffer.length > 1_048_576) { this.close(new Error("Codex app-server message exceeded the size limit.")); return; }
    let newline: number;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, newline);
      this.buffer = this.buffer.slice(newline + 1);
      if (!line.trim()) continue;
      let message: any;
      try { message = JSON.parse(line); }
      catch { this.close(new Error("Invalid Codex app-server protocol response.")); return; }
      if (!message || typeof message !== "object" || Array.isArray(message)) { this.close(new Error("Invalid Codex app-server protocol response.")); return; }
      if (message.method && message.id !== undefined) { this.emit("serverRequest", message); continue; }
      if (message.id !== undefined) {
        const pending = this.pending.get(message.id);
        if (pending) {
          clearTimeout(pending.timer);
          this.pending.delete(message.id);
          if (message.error) pending.reject(new Error("Codex rejected the configured request or sandbox."));
          else pending.resolve(message.result);
        }
      } else if (message.method) this.emit("notification", message);
    }
  }

  private fail(error: Error): void { if (!this.closed) this.close(error); }
}
