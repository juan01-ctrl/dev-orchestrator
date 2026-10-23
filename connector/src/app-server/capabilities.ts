import { isAbsolute, relative, resolve, sep } from "node:path";

const within = (root: string, candidate: unknown): boolean => {
  if (typeof candidate !== "string" || !isAbsolute(candidate)) return false;
  const path = relative(resolve(root), resolve(candidate));
  return path === "" || (!path.startsWith(".." + sep) && path !== ".." && !isAbsolute(path));
};

export function authorizeFileChange(workspace: string, params: any): boolean {
  if (!within(workspace, params?.grantRoot)) return false;
  const path = relative(resolve(workspace), resolve(params.grantRoot));
  return path !== ".git" && !path.startsWith(".git" + sep);
}

export function authorizeCommand(workspace: string, allowedHosts: string[], params: any): boolean | Record<string, unknown> {
  if (params?.cwd && !within(workspace, params.cwd)) return false;
  if (params?.additionalPermissions) return false;
  const amendments = params?.proposedNetworkPolicyAmendments;
  if (!Array.isArray(amendments) || amendments.length === 0) return true;
  if (amendments.length !== 1) return false;
  const amendment = amendments[0];
  if (amendment?.action !== "allow" || !allowedHosts.some(host => host.toLowerCase() === String(amendment.host ?? "").toLowerCase())) return false;
  return { applyNetworkPolicyAmendment: { network_policy_amendment: amendment } };
}
