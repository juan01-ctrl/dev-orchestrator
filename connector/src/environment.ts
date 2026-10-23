import { lstat, readFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { safeText, type BlockerCategory, type CheckResult } from "./task-result.ts";
import { setTimeout as delay } from "node:timers/promises";

export type SandboxCommandResult = { exitCode: number; stdout: string; stderr: string };
export type EnvironmentPlan = { fingerprint: string; setup: string[][]; validate: string[][]; configured: boolean };

export async function detectEnvironment(workspace: string): Promise<EnvironmentPlan> {
  const inputs = new Map<string, string>();
  for (const name of [".dev-orchestrator.json", "package.json", "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock"]) {
    const path = join(workspace, name);
    const info = await lstat(path).catch(error => { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; });
    if (!info) continue;
    if (!info.isFile() || info.isSymbolicLink() || info.size > 5_000_000) throw new Error("Unsafe project environment configuration.");
    inputs.set(name, await readFile(path, "utf8"));
  }
  const fingerprint = createHash("sha256").update(JSON.stringify([...inputs])).digest("hex");
  const commands = (value: unknown): string[][] => {
    if (value === undefined) return [];
    if (!Array.isArray(value) || value.length > 8 || !value.every(argv => Array.isArray(argv) && argv.length > 0 && argv.length <= 40 && argv.every(arg => typeof arg === "string" && arg.length > 0 && arg.length <= 2_000 && !/[\x00\r\n]/.test(arg)))) throw new Error("Invalid project environment configuration: commands must be argv arrays.");
    return value;
  };
  if (inputs.has(".dev-orchestrator.json")) {
    const config = JSON.parse(inputs.get(".dev-orchestrator.json")!);
    if (!config || typeof config !== "object" || Array.isArray(config)) throw new Error("Invalid project environment configuration.");
    return { fingerprint, configured: true, setup: commands(config.setup), validate: commands(config.validate) };
  }
  if (!inputs.has("package.json")) return { fingerprint, configured: false, setup: [], validate: [] };
  const pkg = JSON.parse(inputs.get("package.json")!);
  const manager = inputs.has("pnpm-lock.yaml") ? "pnpm" : inputs.has("yarn.lock") ? "yarn" : inputs.has("bun.lock") ? "bun" : "npm";
  const setup = manager === "npm" ? ["npm", inputs.has("package-lock.json") || inputs.has("npm-shrinkwrap.json") ? "ci" : "install", "--no-audit", "--no-fund"]
    : manager === "pnpm" ? ["pnpm", "install", "--frozen-lockfile"] : manager === "yarn" ? ["yarn", "install", /^yarn@[2-9]/.test(pkg.packageManager ?? "") ? "--immutable" : "--frozen-lockfile"] : ["bun", "install", "--frozen-lockfile"];
  const names = ["check", "typecheck", "lint", "test"].filter(name => typeof pkg.scripts?.[name] === "string");
  if (!names.length && typeof pkg.scripts?.build === "string") names.push("build");
  return { fingerprint, configured: false, setup: [setup], validate: names.map(name => [manager, "run", name]) };
}

export function needsValidation(paths: string[], plan: EnvironmentPlan): boolean {
  return paths.length > 0 && plan.validate.length > 0 && (plan.configured || paths.some(path => !/(?:\.(?:md|txt|rst)|(?:^|\/)(?:LICENSE|NOTICE))$/i.test(path)));
}

export async function runEnvironmentCommands(commands: string[][], execute: (argv: string[]) => Promise<SandboxCommandResult>): Promise<{ checks: CheckResult[]; failure?: { category: BlockerCategory; diagnostic: string } }> {
  const checks: CheckResult[] = [];
  for (const argv of commands) {
    let result: SandboxCommandResult = {exitCode:1,stdout:"",stderr:"Project command could not start."};
    for(let attempt=1;attempt<=3;attempt++) {
      try { result = await execute(argv); }
      catch(error) { result = { exitCode: 1, stdout: "", stderr: error instanceof Error ? error.message : "Project command could not start." }; }
      if(result.exitCode===0 || !networkFailure(result.stdout+"\n"+result.stderr) || attempt===3)break;
      await delay(attempt*250);
    }
    checks.push({ command: safeText(argv.join(" "), 200), status: result.exitCode === 0 ? "passed" : "failed" });
    if (result.exitCode !== 0) {
      const diagnostic = (result.stdout + "\n" + result.stderr).slice(-6_000);
      const category = /command not found|cannot find module|no module named|ENOENT/i.test(diagnostic) ? "environment_setup_failed"
        : networkFailure(diagnostic) ? "network_unavailable" : "validation_failed";
      return { checks, failure: { category, diagnostic } };
    }
  }
  return { checks };
}

function networkFailure(text:string):boolean {
  return /ENOTFOUND|EAI_AGAIN|ECONNRESET|ETIMEDOUT|could not resolve|network.*(?:unavailable|denied)|connection.*(?:refused|timed out)/i.test(text);
}
