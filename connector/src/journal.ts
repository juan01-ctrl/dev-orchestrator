import { mkdir, open, readFile, rename, unlink, lstat } from "node:fs/promises";
import { join, isAbsolute, dirname } from "node:path";
import { randomUUID } from "node:crypto";
import type { JournalState, Lease } from "./types.ts";

export class Journal {
  readonly root: string;
  readonly continuationRoot: string;
  constructor(root: string, continuationRoot = join(root,"continuations")) {
    if (!isAbsolute(root)) throw new Error("Journal directory must be absolute.");
    if (!isAbsolute(continuationRoot)) throw new Error("Continuation directory must be absolute.");
    this.root = root;
    this.continuationRoot = continuationRoot;
  }
  async load(): Promise<JournalState | null> {
    try {
      const path = join(this.root,"active.json");
      const stat = await lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077)) throw new Error("Unsafe journal file.");
      const state = JSON.parse(await readFile(path,"utf8"));
      if (!state.lease?.id || !Number.isInteger(state.sequence)) throw new Error("Corrupt journal; manual recovery is required.");
      return state;
    } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return null; throw error; }
  }
  async save(state: JournalState): Promise<void> {
    await mkdir(this.root,{recursive:true,mode:0o700});
    const info = await lstat(this.root);
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error("Unsafe journal directory.");
    const temp = join(this.root,".journal-" + randomUUID());
    const file = await open(temp,"wx",0o600);
    try {
      await file.writeFile(JSON.stringify(state)); await file.sync(); await file.close();
      await rename(temp,join(this.root,"active.json"));
    } catch (error) { await file.close().catch(()=>{}); await unlink(temp).catch(()=>{}); throw error; }
  }
  async clear(): Promise<void> {
    await unlink(join(this.root,"active.json")).catch((e: NodeJS.ErrnoException) => { if (e.code !== "ENOENT") throw e; });
  }

  private continuationPath(lease: Lease): string {
    if(!/^[a-zA-Z0-9_-]{1,100}$/.test(lease.id) || !Number.isInteger(lease.lifecycle) || lease.lifecycle<1)throw new Error("Invalid continuation identity.");
    return join(this.continuationRoot,`${lease.id}-${lease.lifecycle}`,"active.json");
  }

  async preserveCompleted(state: JournalState): Promise<void> {
    const checkpoint=new Journal(dirname(this.continuationPath(state.lease)));
    await checkpoint.save(state);
  }

  async park(state: JournalState): Promise<void> {
    await this.preserveCompleted(state);
    await this.clear();
  }

  async resumeContinuation(lease: Lease): Promise<JournalState|null> {
    const path=this.continuationPath(lease);
    const info=await lstat(path).catch(error=>{if((error as NodeJS.ErrnoException).code==="ENOENT")return null;throw error;});
    if(!info)return null;
    if(!info.isFile() || info.isSymbolicLink() || (info.mode&0o077))throw new Error("Unsafe continuation checkpoint.");
    const state=JSON.parse(await readFile(path,"utf8")) as JournalState;
    if(state.lease?.id!==lease.id || state.lease.lifecycle!==lease.lifecycle || state.lease.generation>=lease.generation || !state.thread_id || !state.workspace || !state.baseline)throw new Error("Continuation does not match the preserved attempt.");
    if(state.lease.snapshot?.task_branch!==lease.snapshot?.task_branch)throw new Error("Continuation branch changed.");
    state.lease=lease;state.sequence=lease.sequence??0;state.phase="implement";
    state.deadline_at=typeof lease.snapshot?.execution_deadline_at_ms==="number"?lease.snapshot.execution_deadline_at_ms:Date.now()+20*60_000;
    state.attempts=0;state.publication_attempts=0;state.verification_attempts=0;
    state.continuation_started=false;
    delete state.pending_event;delete state.result;delete state.candidate;delete state.repair_context;
    await this.save(state);await unlink(path);
    return state;
  }
  async archive(reason: string): Promise<void> {
    const state=await this.load();
    if(!state)return;
    const directory=join(this.root,"archive");
    await mkdir(directory,{recursive:true,mode:0o700});
    const safeReason=reason.replace(/[^a-z0-9_-]/gi,"_").slice(0,40)||"superseded";
    const name=`${state.lease.id}-${state.lease.lifecycle}-${Date.now()}-${safeReason}.json`;
    await rename(join(this.root,"active.json"),join(directory,name));
  }
}
