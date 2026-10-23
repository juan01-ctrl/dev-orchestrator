import { mkdir, open, readFile, rename, unlink, lstat } from "node:fs/promises";
import { join, isAbsolute } from "node:path";
import { randomUUID } from "node:crypto";
import type { JournalState } from "./types.ts";

export class Journal {
  readonly root: string;
  constructor(root: string) {
    if (!isAbsolute(root)) throw new Error("Journal directory must be absolute.");
    this.root = root;
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
