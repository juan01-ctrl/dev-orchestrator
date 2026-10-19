export type Mapping = { projectId: string; repository: string; baseBranch: string; source: string; workspaceRoot: string };
export type Config = { version: 1; server: string; token: string; mappings: Mapping[]; codexBinary?: string };
export type Lease = { id: string; generation: number; lifecycle: number; project_id?: string; title?: string; prompt?: string; source_key?: string; snapshot?: Record<string, unknown>; expires_in_ms?: number; sequence?: number };
export type RunEvent = { sequence: number; kind: string; data: Record<string, unknown> };
export type JournalState = { lease: Lease; sequence: number; pending_event?: RunEvent; workspace?: string; baseline?: string };
