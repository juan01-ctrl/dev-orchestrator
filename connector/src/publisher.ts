import { mkdtemp, readFile, writeFile, rm, realpath, lstat, access, mkdir } from "node:fs/promises";
import { join, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { command, cleanGitEnv } from "./process.ts";
import { withGitHubCredential, validateGitHubCredential } from "./git-credential.ts";
import type { GitHubCredential } from "./types.ts";
import { validBranch, validRepository } from "./workspace.ts";

export type PublicationContext={workspace:string;repository:string;baseBranch:string;branch:string;baseline:string;gitDir:string;commonDir:string;previousHead?:string;previousPullRequest?:string};
type Dependencies={runCommand?:typeof command;apiFetch?:typeof fetch;remoteURL?:(repository:string)=>string};
const validSHA=(sha:string)=>/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(sha);

export class Publisher {
  readonly context:PublicationContext;
  private readonly runCommand:typeof command;
  private readonly apiFetch:typeof fetch;
  private readonly remoteURL:(repository:string)=>string;

  constructor(context:PublicationContext,dependencies:Dependencies={}) {
    if(context.previousHead!==undefined && !validSHA(context.previousHead))throw new Error("Invalid previous delivery head.");
    const previousPrefix=`https://github.com/${context.repository}/pull/`;
    if(context.previousPullRequest!==undefined && (!context.previousHead || !context.previousPullRequest.startsWith(previousPrefix) || !/^[0-9]+$/.test(context.previousPullRequest.slice(previousPrefix.length))))throw new Error("Invalid previous pull request.");
    if(!validRepository(context.repository) || !validBranch(context.branch) || !validBranch(context.baseBranch) || context.branch===context.baseBranch || !(context.branch.startsWith("task/") || context.branch.startsWith("task-attempts/")) || !validSHA(context.baseline) || !context.gitDir || !context.commonDir)throw new Error("Invalid publication context.");
    this.context=context;
    this.runCommand=dependencies.runCommand??command;
    this.apiFetch=dependencies.apiFetch??fetch;
    this.remoteURL=dependencies.remoteURL??(repository=>`https://github.com/${repository}.git`);
  }

  async status(signal?:AbortSignal):Promise<{changed:boolean;commit:string}> {
    return this.trusted(async(git,sha)=>{
      const uncommitted=await git(["diff","--no-ext-diff","--no-textconv","--quiet",sha,"--"],true);
      const untracked=await git(["ls-files","--others","--exclude-standard"]);
      if(uncommitted.code!==0 || untracked.output)throw new Error("Uncommitted changes remain. The trusted connector must commit the task before publication.");
      const diff=await git(["diff","--no-ext-diff","--no-textconv","--quiet",this.context.previousHead??this.context.baseline,sha,"--"],true);
      return {changed:diff.code===1,commit:sha};
    },signal);
  }

  async changedFiles(signal?: AbortSignal): Promise<string[]> {
    return this.trusted(async git => {
      const tracked = await git(["diff", "--name-only", "-z", "--no-ext-diff", "--no-textconv", this.context.baseline, "--"]);
      const untracked = await git(["ls-files", "--others", "--exclude-standard", "-z"]);
      return [...new Set((tracked.output + untracked.output).split("\0").filter(Boolean))];
    }, signal);
  }

  async reviewSnapshot<T>(commit: string, inspect: (workspace: string) => Promise<T>, signal?: AbortSignal): Promise<T> {
    if (!validSHA(commit)) throw new Error("Invalid review candidate.");
    return this.trusted(async (git, sha, temp) => {
      if (sha !== commit) throw new Error("Candidate head changed before review.");
      await git(["update-ref", "refs/heads/review-candidate", commit]);
      await git(["update-ref", "refs/heads/review-base", this.context.baseline]);
      const bundle = join(temp, "review.bundle");
      await git(["bundle", "create", bundle, "refs/heads/review-candidate", "refs/heads/review-base"]);
      const workspace = join(temp, "review");
      const env = cleanGitEnv();
      await this.runCommand("git", ["-c", "core.hooksPath=/dev/null", "clone", "--no-local", "--no-checkout", "--template=", "--", bundle, workspace], { env, signal });
      const isolated = (args: string[]) => this.runCommand("git", ["-C", workspace, "-c", "core.hooksPath=/dev/null", "-c", "core.attributesFile=/dev/null", ...args], { env, signal });
      await isolated(["config", "--remove-section", "remote.origin"]);
      await isolated(["update-ref", "refs/heads/review-base", this.context.baseline]);
      await isolated(["checkout", "--detach", commit]);
      if ((await isolated(["rev-parse", "HEAD"])).output !== commit) throw new Error("Review candidate changed.");
      return inspect(await realpath(workspace));
    }, signal);
  }

  async commit(identifier:string,author:Pick<GitHubCredential,"author_name"|"author_email">,signal?:AbortSignal):Promise<{changed:boolean;commit:string}> {
    if(!/^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/.test(identifier) ||
      !author?.author_name || author.author_name.length>200 || /[\r\n\x00]/.test(author.author_name) ||
      !author?.author_email || author.author_email.length>254 || /[\r\n\x00]/.test(author.author_email))throw new Error("Invalid task commit identity.");
    return this.trusted(async(git,sha,_temp,objects,gitDir,commonDir)=>{
      await git(["add","--all","--"]);
      const staged=await git(["diff","--cached","--no-ext-diff","--no-textconv","--quiet",sha,"--"],true);
      if(staged.code===0)return {changed:sha!==this.context.baseline,commit:sha};
      const tree=(await git(["write-tree"])).output;
      if(!validSHA(tree))throw new Error("Invalid staged task tree.");
      const authorEnv={...cleanGitEnv(),GIT_OBJECT_DIRECTORY:objects,
        GIT_AUTHOR_NAME:author.author_name,GIT_AUTHOR_EMAIL:author.author_email,
        GIT_COMMITTER_NAME:author.author_name,GIT_COMMITTER_EMAIL:author.author_email};
      const next=(await git(["commit-tree",tree,"-p",sha,"-m",`chore: deliver ${identifier}`],false,authorEnv)).output;
      if(!validSHA(next))throw new Error("Invalid task commit.");
      const env=cleanGitEnv();
      await this.runCommand("git",["--git-dir",gitDir,"--work-tree",this.context.workspace,"-c","core.hooksPath=/dev/null","-c","core.attributesFile=/dev/null","read-tree",next],{env,signal});
      await this.runCommand("git",["--git-dir",commonDir,"-c","core.hooksPath=/dev/null","update-ref",`refs/heads/${this.context.branch}`,next,sha],{env,signal});
      return {changed:next!==this.context.baseline,commit:next};
    },signal);
  }

  async publish(title:string,body:string,credential:GitHubCredential,signal?:AbortSignal,expectedCommit?:string):Promise<Record<string,string>> {
    if(expectedCommit!==undefined && !validSHA(expectedCommit))throw new Error("Invalid reviewed candidate.");
    if(!title.trim() || title.length>240 || body.length>64_000)throw new Error("Invalid PR metadata.");
    validateGitHubCredential(credential);
    const status=await this.status(signal);
    if(!status.changed)throw new Error("No committed changes to publish.");
    return this.trusted(async(git,sha,temp,objects)=>{
      if(expectedCommit!==undefined && sha!==expectedCommit)throw new Error("Candidate changed after independent review; publication stopped.");
      const previousPath=this.context.previousPullRequest?`/repos/${this.context.repository}/pulls/${this.context.previousPullRequest.split("/").at(-1)}`:undefined;
      if(previousPath) {
        const previous=await this.githubRequest("GET",previousPath,credential,undefined,signal);
        if(!previous.ok || !(this.matchesPullRequest(previous.body,this.context.previousHead!) || this.matchesPullRequest(previous.body,sha)))throw new Error("The existing pull request changed or closed; repair publication stopped.");
      }
      await withGitHubCredential(temp,credential,env=>git(["push","--no-verify",this.remoteURL(this.context.repository),`${sha}:refs/heads/${this.context.branch}`],false,{...env,GIT_OBJECT_DIRECTORY:objects}));
      let pr=previousPath?(await this.githubRequest("GET",previousPath,credential,undefined,signal)).body:await this.findOpenPullRequest(credential,signal);
      if(!pr && !previousPath) {
        const [owner]=this.context.repository.split("/");
        const created=await this.githubRequest("POST",`/repos/${this.context.repository}/pulls`,credential,{
          title,
          head:`${owner}:${this.context.branch}`,
          base:this.context.baseBranch,
          body,
          draft:false
        },signal);
        if(created.status===422)pr=await this.findOpenPullRequest(credential,signal);
        else if(created.ok)pr=created.body;
        else throw new Error("GitHub could not create a pull request for this branch.");
      }
      if(!this.matchesPullRequest(pr,sha))throw new Error("GitHub pull request does not match the task commit.");
      return {repository:this.context.repository,branch:this.context.branch,base_branch:this.context.baseBranch,commit:sha,pr_url:pr.html_url};
    },signal);
  }

  async summaryComment(prURL: string, commit: string, body: string, credential: GitHubCredential, signal?: AbortSignal, lookupOnly=false): Promise<"sent" | "ambiguous" | "rejected"> {
    validateGitHubCredential(credential);
    const prefix = `https://github.com/${this.context.repository}/pull/`;
    if (!prURL.startsWith(prefix) || !/^[1-9][0-9]*$/.test(prURL.slice(prefix.length)) || !validSHA(commit) || body.length > 60_000) throw new Error("Invalid PR summary target.");
    const number = prURL.slice(prefix.length), marker = `<!-- dev-orchestrator-summary:${commit} -->`;
    const own = (comment: any) => comment?.user?.login === credential.author_name && typeof comment.body === "string" && comment.body.startsWith(marker + "\n");
    try {
      const pr = await this.githubRequest("GET", `/repos/${this.context.repository}/pulls/${number}`, credential, undefined, signal);
      if (!pr.ok || !this.matchesPullRequest(pr.body, commit)) return "rejected";
      for (let page = 1; page <= 3; page++) {
        const response = await this.githubRequest("GET", `/repos/${this.context.repository}/issues/${number}/comments?per_page=100&page=${page}`, credential, undefined, signal);
        if (!response.ok || !Array.isArray(response.body)) return "rejected";
        if (response.body.some(own)) return "sent";
        if (response.body.length < 100) break;
        if (page === 3) return "rejected";
      }
    } catch { return "rejected"; } // No write was attempted.
    if(lookupOnly)return "ambiguous";
    try {
      const response = await this.githubRequest("POST", `/repos/${this.context.repository}/issues/${number}/comments`, credential, { body: marker + "\n" + body }, signal);
      if (response.ok) return own(response.body) && Number.isSafeInteger(response.body.id) ? "sent" : "ambiguous";
      return response.status >= 500 ? "ambiguous" : "rejected";
    } catch { return "ambiguous"; } // Accepted-but-unacknowledged writes are never blindly repeated.
  }

  private async findOpenPullRequest(credential:GitHubCredential,signal?:AbortSignal):Promise<any|undefined> {
    const [owner]=this.context.repository.split("/");
    const query=new URLSearchParams({state:"open",head:`${owner}:${this.context.branch}`,per_page:"100"});
    const response=await this.githubRequest("GET",`/repos/${this.context.repository}/pulls?${query}`,credential,undefined,signal);
    if(!response.ok || !Array.isArray(response.body))throw new Error("GitHub pull request lookup failed.");
    const sameBranch=response.body.filter((pr:any)=>pr?.head?.ref===this.context.branch && pr?.head?.repo?.full_name===this.context.repository);
    const exact=sameBranch.find((pr:any)=>pr?.base?.ref===this.context.baseBranch && pr?.base?.repo?.full_name===this.context.repository);
    if(sameBranch.length && !exact)throw new Error("An open pull request exists for this task branch with a different base repository or branch.");
    return exact;
  }

  private matchesPullRequest(pr:any,sha:string):boolean {
    const escaped=this.context.repository.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
    return pr?.state==="open" && pr?.head?.sha===sha && pr?.head?.ref===this.context.branch &&
      pr?.head?.repo?.full_name===this.context.repository && pr?.base?.ref===this.context.baseBranch &&
      pr?.base?.repo?.full_name===this.context.repository &&
      new RegExp(`^https://github\\.com/${escaped}/pull/[0-9]+$`).test(pr?.html_url??"");
  }

  private async githubRequest(method:"GET"|"POST",path:string,credential:GitHubCredential,body?:Record<string,string|boolean>,signal?:AbortSignal):Promise<{ok:boolean;status:number;body:any}> {
    const timeout=AbortSignal.timeout(15_000);
    const requestSignal=signal?AbortSignal.any([signal,timeout]):timeout;
    let response:Response;
    try {
      response=await this.apiFetch("https://api.github.com"+path,{
        method,redirect:"error",signal:requestSignal,
        headers:{authorization:`Bearer ${credential.token}`,accept:"application/vnd.github+json","x-github-api-version":"2022-11-28","content-type":"application/json","user-agent":"dev-orchestrator"},
        ...(body?{body:JSON.stringify(body)}:{})
      });
    } catch {throw new Error("GitHub pull request service is temporarily unavailable.");}
    let payload:any;
    try {payload=await response.json();} catch {throw new Error("GitHub returned an invalid pull request response.");}
    return {ok:response.ok,status:response.status,body:payload};
  }

  private async trusted<T>(fn:(git:(args:string[],allowExitOne?:boolean,commandEnv?:NodeJS.ProcessEnv)=>Promise<{output:string;code:number}>,sha:string,temp:string,objects:string,gitDir:string,commonDir:string)=>Promise<T>,signal?:AbortSignal):Promise<T> {
    const workspace=await realpath(this.context.workspace);
    const pointer=join(workspace,".git");
    const stat=await lstat(pointer);
    if(stat.isSymbolicLink() || (!stat.isDirectory() && !stat.isFile()))throw new Error("Publication needs valid Git metadata.");
    if(stat.isDirectory())throw new Error("Publication requires connector-managed Git metadata.");
    const content=await readFile(pointer,"utf8");
    const match=content.match(/^gitdir: (.+)\r?\n?$/);
    if(!match)throw new Error("Publication needs valid Git worktree metadata.");
    const pointerGitDir=await realpath(resolve(workspace,match[1]));
    const gitDir=await realpath(this.context.gitDir);
    const commonDir=await realpath(this.context.commonDir);
    if(pointerGitDir!==gitDir || await realpath(join(gitDir,"..",".."))!==commonDir)throw new Error("Task Git metadata changed after workspace preparation.");
    const worktrees=await realpath(join(commonDir,"worktrees"));
    if(!gitDir.startsWith(worktrees+sep) || gitDir.slice(worktrees.length+1).includes(sep))throw new Error("Publication worktree metadata escaped its repository.");
    const objects=await realpath(join(commonDir,"objects"));
    if(!objects.startsWith(commonDir+sep))throw new Error("Publication needs an internal Git object directory.");
    for(const forbidden of ["info/alternates","info/http-alternates"]) {
      try {await access(join(objects,forbidden));throw new Error("External Git object stores are not supported.");}
      catch(error) {if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;}
    }
    const head=await readFile(join(gitDir,"HEAD"),"utf8");
    if(head.trim()!==`ref: refs/heads/${this.context.branch}`)throw new Error("Task branch changed unexpectedly.");
    const ref=join(commonDir,"refs","heads",this.context.branch);
    const resolved=await realpath(ref);
    if(!resolved.startsWith(commonDir+sep))throw new Error("Unsafe Git reference.");
    const sha=(await readFile(ref,"utf8")).trim();
    if(!validSHA(sha))throw new Error("Invalid task commit.");
    const temporary=await mkdtemp(join(tmpdir(),"dev-orchestrator-publish-"));
    try {
      const bare=join(temporary,"repo.git");
      await this.runCommand("git",["init","--bare","--template=",bare],{signal});
      await mkdir(join(bare,"info"),{mode:0o700});
      const excludes=join(commonDir,"info","exclude");
      const excludesInfo=await lstat(excludes).catch(error=>{if((error as NodeJS.ErrnoException).code==="ENOENT")return undefined;throw error;});
      if(excludesInfo) {
        if(!excludesInfo.isFile() || excludesInfo.isSymbolicLink() || excludesInfo.size>1_048_576)throw new Error("Unsafe Git exclude metadata.");
        await writeFile(join(bare,"info","exclude"),await readFile(excludes,"utf8"),{mode:0o600});
      }
      try {
        const shallow=await readFile(join(commonDir,"shallow"),"utf8");
        if(!shallow.trim().split("\n").every(validSHA))throw new Error("Invalid shallow boundary.");
        await writeFile(join(bare,"shallow"),shallow,{mode:0o600});
      } catch(error) {if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;}
      const env={...cleanGitEnv(),GIT_OBJECT_DIRECTORY:objects};
      const git=(args:string[],allowExitOne=false,commandEnv:NodeJS.ProcessEnv=env)=>this.runCommand("git",["--git-dir",bare,"--work-tree",workspace,"-c","core.bare=false","-c","core.hooksPath=/dev/null","-c","core.attributesFile=/dev/null","-c","filter.lfs.clean=cat","-c","filter.lfs.smudge=cat","-c","filter.lfs.required=false",...args],{cwd:temporary,env:commandEnv,signal,allowExitOne});
      await git(["read-tree",sha]);
      return await fn(git,sha,temporary,objects,gitDir,commonDir);
    } finally {await rm(temporary,{recursive:true,force:true});}
  }
}
