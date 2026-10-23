import { serverURL } from "./config.ts";
import { createHash } from "node:crypto";
import type { Lease } from "./types.ts";
export class APIError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string) { super(`Control plane request failed (${status}: ${code}).`); this.status=status; this.code=code; }
}

export class API {
  readonly origin: string;
  readonly token: string | undefined;
  constructor(origin: string, token?: string) { this.origin=serverURL(origin); this.token=token; }
  async post(path: string, data: unknown): Promise<any> {
    if (!/^\/[a-z/-]+$/.test(path)) throw new Error("Invalid control-plane route.");
    const response = await fetch(this.origin + "/api/v1" + path, {
      method: "POST", redirect: "error", signal: AbortSignal.timeout(15_000),
      headers: { "content-type":"application/json", ...(this.token ? {authorization:`Bearer ${this.token}`} : {}) },
      body: JSON.stringify(data)
    });
    const body = await response.json() as Record<string,unknown>;
    if (!response.ok) throw new APIError(response.status, typeof body.error === "string" && /^[a-z_]+$/.test(body.error) ? body.error : "request_failed");
    return path === "/enroll" ? body : body.data;
  }

  async downloadAsset(lease: Lease, assetId: string, maxBytes = 10 * 1024 * 1024): Promise<{ body: Buffer; filename: string; mediaType: string; sha256: string }> {
    if (!/^[0-9a-f-]{36}$/i.test(assetId) || !Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new Error("Invalid task asset request.");
    const response = await fetch(this.origin + "/api/v1/executor/assets", {
      method: "POST", redirect: "error", signal: AbortSignal.timeout(15_000),
      headers: { "content-type": "application/json", ...(this.token ? { authorization: `Bearer ${this.token}` } : {}) },
      body: JSON.stringify({ lease, asset_id: assetId })
    });
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw new Error(response.status === 404 ? "Task asset is unavailable." : response.status === 409 ? "Task lease expired." : response.status === 422 ? "Task asset was rejected." : "Task asset download failed.");
    }
    const declaredSize = Number(response.headers.get("x-dev-orchestrator-size"));
    const expectedHash = response.headers.get("x-dev-orchestrator-sha256") ?? "";
    const filename = response.headers.get("content-disposition")?.match(/filename="([A-Za-z0-9._ -]{1,140})"/i)?.[1];
    const mediaType = (response.headers.get("content-type") ?? "").split(";", 1)[0].toLowerCase();
    if (!Number.isSafeInteger(declaredSize) || declaredSize < 0 || declaredSize > maxBytes || !/^[a-f0-9]{64}$/.test(expectedHash) || !filename || !/^[a-z0-9.+-]+\/[a-z0-9.+-]+$/.test(mediaType) || !response.body) {
      await response.body?.cancel().catch(() => {});
      throw new Error("Task asset response metadata is invalid.");
    }
    const reader = response.body.getReader();
    const chunks: Buffer[] = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maxBytes) throw new Error("Task asset exceeds the allowed size.");
        chunks.push(Buffer.from(value));
      }
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw error;
    }
    const body = Buffer.concat(chunks);
    const sha256 = createHash("sha256").update(body).digest("hex");
    if (size !== declaredSize || sha256 !== expectedHash) throw new Error("Task asset integrity check failed.");
    return { body, filename, mediaType, sha256 };
  }
}
