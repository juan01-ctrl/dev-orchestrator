import { randomUUID } from "node:crypto";
import { open, lstat, readFile, unlink, type FileHandle } from "node:fs/promises";
import type { Stats } from "node:fs";

type Identity = Pick<Stats, "dev" | "ino">;
type LockRecord = { pid: number; token?: string };

function sameFile(left: Identity, right: Identity): boolean {
  return left.dev === right.dev && left.ino === right.ino;
}

async function readRecord(path: string): Promise<{ record: LockRecord; identity: Identity }> {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077) !== 0) {
    throw new Error("Connector lock is unsafe; refusing automatic recovery.");
  }

  const content = await readFile(path, "utf8");
  let record: LockRecord;
  try {
    const parsed: unknown = JSON.parse(content);
    if (!parsed || typeof parsed !== "object") throw new Error("invalid");
    const value = parsed as Record<string, unknown>;
    if (!Number.isSafeInteger(value.pid) || Number(value.pid) < 1) throw new Error("invalid");
    record = { pid: Number(value.pid), ...(typeof value.token === "string" ? { token: value.token } : {}) };
  } catch {
    const legacyPid = content.trim();
    if (!/^\d+$/.test(legacyPid) || Number(legacyPid) < 1) {
      throw new Error("Connector lock is invalid; refusing automatic recovery.");
    }
    record = { pid: Number(legacyPid) };
  }

  return { record, identity: info };
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "EPERM") return true;
    if (code === "ESRCH") return false;
    throw new Error("Unable to verify connector lock owner; refusing automatic recovery.");
  }
}

async function unlinkIfSame(path: string, identity: Identity): Promise<boolean> {
  try {
    const current = await lstat(path);
    if (!current.isFile() || current.isSymbolicLink() || !sameFile(current, identity)) return false;
    await unlink(path);
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

async function recoverStaleLock(path: string): Promise<void> {
  const recoveryPath = `${path}.recovery`;
  let recovery: FileHandle;
  try {
    recovery = await open(recoveryPath, "wx", 0o600);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    let existing;
    try {
      existing = await readRecord(recoveryPath);
    } catch {
      throw new Error("Connector lock recovery is already in progress; confirm no connector is running.");
    }
    if (processIsAlive(existing.record.pid)) {
      throw new Error("Connector lock recovery is already in progress.");
    }
    if (!(await unlinkIfSame(recoveryPath, existing.identity))) {
      throw new Error("Connector lock changed during recovery; retry the command.");
    }
    recovery = await open(recoveryPath, "wx", 0o600).catch(() => {
      throw new Error("Connector lock recovery is already in progress.");
    });
  }

  const recoveryIdentity = await recovery.stat();
  const recoveryToken = randomUUID();
  await recovery.writeFile(JSON.stringify({ pid: process.pid, token: recoveryToken }));
  await recovery.sync();

  try {
    let existing;
    try {
      existing = await readRecord(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    if (processIsAlive(existing.record.pid)) {
      throw new Error(`Connector is already running (pid ${existing.record.pid}).`);
    }
    if (!(await unlinkIfSame(path, existing.identity))) {
      throw new Error("Connector lock changed during recovery; retry the command.");
    }
  } finally {
    await recovery.close();
    const current = await lstat(recoveryPath).catch(() => undefined);
    if (current && sameFile(current, recoveryIdentity) && !current.isSymbolicLink()) {
      const record = await readFile(recoveryPath, "utf8").catch(() => "");
      if (record.includes(recoveryToken)) await unlink(recoveryPath).catch(() => {});
    }
  }
}

export class ConnectorLock {
  private released = false;
  private readonly path: string;
  private readonly handle: FileHandle;
  private readonly identity: Identity;
  private readonly token: string;

  private constructor(path: string, handle: FileHandle, identity: Identity, token: string) {
    this.path = path;
    this.handle = handle;
    this.identity = identity;
    this.token = token;
  }

  static async acquire(path: string): Promise<ConnectorLock> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const token = randomUUID();
      try {
        const handle = await open(path, "wx", 0o600);
        try {
          await handle.writeFile(JSON.stringify({ pid: process.pid, token }));
          await handle.sync();
          const info = await handle.stat();
          return new ConnectorLock(path, handle, info, token);
        } catch (error) {
          await handle.close().catch(() => {});
          await unlink(path).catch(() => {});
          throw error;
        }
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        if (attempt > 0) throw new Error("Connector lock changed while starting; retry the command.");
        await recoverStaleLock(path);
      }
    }
    throw new Error("Unable to acquire connector lock.");
  }

  async release(): Promise<void> {
    if (this.released) return;
    this.released = true;
    await this.handle.close();
    const current = await lstat(this.path).catch(() => undefined);
    if (!current || !current.isFile() || current.isSymbolicLink() || !sameFile(current, this.identity)) return;
    const content = await readFile(this.path, "utf8").catch(() => "");
    if (content.includes(this.token)) await unlink(this.path).catch(() => {});
  }
}
