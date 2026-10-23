import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { GitHubCredential } from "./types.ts";
import { cleanGitEnv } from "./process.ts";

export type GitHubCredentialFailureReason="unavailable"|"invalid_token_format"|"invalid_expiration"|"expired_token"|"invalid_author";
export class GitHubCredentialFailure extends Error {
  readonly reason:GitHubCredentialFailureReason;
  constructor(reason:GitHubCredentialFailureReason) {
    super("GitHub authorization is invalid or expired.");
    this.reason=reason;
  }
}

export function validateGitHubCredential(value: unknown): asserts value is GitHubCredential {
  if (!value || typeof value !== "object") throw new GitHubCredentialFailure("unavailable");
  const credential=value as Partial<GitHubCredential>;
  if (typeof credential.token!=="string" || !/^[A-Za-z0-9_-]+$/.test(credential.token))throw new GitHubCredentialFailure("invalid_token_format");
  if (typeof credential.expires_at!=="string" || !Number.isFinite(Date.parse(credential.expires_at)))throw new GitHubCredentialFailure("invalid_expiration");
  if (Date.parse(credential.expires_at)<=Date.now())throw new GitHubCredentialFailure("expired_token");
  if (typeof credential.author_name!=="string" || !credential.author_name || credential.author_name.length>200 || /[\r\n]/.test(credential.author_name) ||
      typeof credential.author_email!=="string" || !credential.author_email || credential.author_email.length>254 || /[\r\n]/.test(credential.author_email)) {
    throw new GitHubCredentialFailure("invalid_author");
  }
}

export async function withGitHubCredential<T>(root:string, credential:GitHubCredential, operation:(env:NodeJS.ProcessEnv)=>Promise<T>):Promise<T> {
  validateGitHubCredential(credential);
  const directory=await mkdtemp(join(root,".github-auth-"));
  try {
    await chmod(directory,0o700);
    const helper=join(directory,"askpass");
    const script=`#!/bin/sh\ncase "$1" in\n  *sername*) printf '%s\\n' 'x-access-token' ;;\n  *assword*) printf '%s\\n' '${credential.token}' ;;\n  *) exit 1 ;;\nesac\n`;
    await writeFile(helper,script,{encoding:"utf8",mode:0o700,flag:"wx"});
    return await operation({...cleanGitEnv(),GIT_ASKPASS:helper,SSH_ASKPASS:helper,GIT_TERMINAL_PROMPT:"0"});
  } finally {
    await rm(directory,{recursive:true,force:true});
  }
}
