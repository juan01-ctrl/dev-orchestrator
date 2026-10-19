import { lstat, readFile, mkdir, open, rename, unlink } from "node:fs/promises";
import { dirname, isAbsolute } from "node:path";
import { randomUUID } from "node:crypto";
import type { Config } from "./types.ts";

export function serverURL(value: string): string {
  const url = new URL(value);
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(local && url.protocol === "http:")) || url.username || url.password || url.search || url.hash || url.pathname !== "/") throw new Error("Use an HTTPS server origin (loopback HTTP is allowed for development).");
  return url.origin;
}

export async function loadConfig(path: string): Promise<Config> {
  if (!isAbsolute(path)) throw new Error("Configuration path must be absolute.");
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077) !== 0) throw new Error("Configuration must be a regular owner-only file (chmod 600).");
  const config = JSON.parse(await readFile(path,"utf8"));
  if (config.version !== 1 || typeof config.token !== "string" || !config.token || !Array.isArray(config.mappings)) throw new Error("Invalid connector configuration.");
  config.server = serverURL(config.server);
  return config;
}

export async function saveConfig(path: string, config: Config, exclusive = false): Promise<void> {
  if (!isAbsolute(path)) throw new Error("Configuration path must be absolute.");
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  if (!exclusive) {
    try { await loadConfig(path); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; }
  }
  if (exclusive) {
    const file = await open(path,"wx",0o600);
    try { await file.writeFile(JSON.stringify(config,null,2)); await file.sync(); } finally { await file.close(); }
  } else {
    const temporary = path + ".tmp-" + randomUUID();
    const file = await open(temporary,"wx",0o600);
    try {
      await file.writeFile(JSON.stringify(config,null,2)); await file.sync();
      await file.close(); await rename(temporary,path);
    } catch (error) { await file.close().catch(()=>{}); await unlink(temporary).catch(()=>{}); throw error; }
  }
}
