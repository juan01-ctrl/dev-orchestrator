export type ServerRequest = { id: string | number; method: string; params: any };
export type RequestResolution = { id: string | number; result?: unknown; error?: { code: number; message: string } };

export type RequestHandlers = {
  authorizeCommand?: (params: any) => boolean | Promise<boolean>;
  authorizeFileChange?: (params: any) => boolean | Promise<boolean>;
  requestUserInput?: (params: any) => unknown | Promise<unknown>;
  requestPermissions?: (params: any) => unknown | Promise<unknown>;
  requestElicitation?: (params: any) => unknown | Promise<unknown>;
  callDynamicTool?: (params: any) => unknown | Promise<unknown>;
};

const error = (id: string | number, code: number, message: string): RequestResolution => ({ id, error: { code, message } });

export async function resolveServerRequest(handlers: RequestHandlers, requests: ServerRequest[]): Promise<RequestResolution[]> {
  return Promise.all(requests.map(async request => {
    try {
      switch (request.method) {
        case "item/commandExecution/requestApproval":
          return { id: request.id, result: { decision: await handlers.authorizeCommand?.(request.params) ? "accept" : "decline" } };
        case "item/fileChange/requestApproval":
          return { id: request.id, result: { decision: await handlers.authorizeFileChange?.(request.params) ? "accept" : "decline" } };
        case "item/tool/requestUserInput":
          return handlers.requestUserInput ? { id: request.id, result: await handlers.requestUserInput(request.params) } : error(request.id, -32000, "Additional task context is required.");
        case "item/permissions/requestApproval":
          return handlers.requestPermissions ? { id: request.id, result: await handlers.requestPermissions(request.params) } : error(request.id, -32000, "The requested permissions are outside the execution policy.");
        case "mcpServer/elicitation/request":
          return handlers.requestElicitation ? { id: request.id, result: await handlers.requestElicitation(request.params) } : { id: request.id, result: { action: "decline", content: null, _meta: null } };
        case "item/tool/call":
          return handlers.callDynamicTool ? { id: request.id, result: await handlers.callDynamicTool(request.params) } : { id: request.id, result: { success: false, contentItems: [] } };
        default: return error(request.id, -32601, "Unsupported Codex app-server request.");
      }
    } catch { return error(request.id, -32000, "The requested action could not be authorized."); }
  }));
}
