export type Config = { version: 2; server: string; token: string; codexBinary?: string };
export type TokenPurpose = "checkout" | "publish";
export type GitHubCredential = { token: string; expires_at: string; author_name: string; author_email: string };
export type Lease = { id: string; generation: number; lifecycle: number; project_id?: string; title?: string; prompt?: string; source_key?: string; snapshot?: Record<string, unknown>; expires_in_ms?: number; sequence?: number };
export type RunEvent = { sequence: number; kind: string; data: Record<string, unknown> };
export type JournalState = {
  lease: Lease; sequence: number; pending_event?: RunEvent;
  workspace?: string; baseline?: string; thread_id?: string;
  phase?: "implement" | "validate" | "publish" | "verify";
  result?: import("./task-result.ts").TaskResult; candidate?: Record<string, string>;
  attempts?: number; deadline_at?: number; environment_fingerprint?: string;
  verification_attempts?: number; publication_attempts?: number;
  repair_context?: string;
};
