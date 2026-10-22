import { serverURL } from "./config.ts";
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
}
