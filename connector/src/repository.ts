import { createHash, randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { command, CommandFailure } from "./process.ts";
import { GitHubCredentialFailure, withGitHubCredential } from "./git-credential.ts";
import type { GitHubCredential, Lease } from "./types.ts";
import { validBranch, validRepository } from "./workspace.ts";

type Marker={run:string;lifecycle:number;project:string;repository:string;base_branch:string;baseline:string;branch:string};
type Options={remoteURL?:(repository:string)=>string;runCommand?:typeof command};
export type RepositoryFailureCategory="github_permission_denied"|"github_unavailable"|"base_branch_missing"|"workspace_setup_failed";
export class RepositoryPreparationFailure extends Error {
  readonly category:RepositoryFailureCategory;
  constructor(category:RepositoryFailureCategory) {
    super("Repository preparation failed.");
    this.category=category;
  }
}
const validId=(value:unknown):value is string=>typeof value==="string" && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
const validSHA=(value:unknown):value is string=>typeof value==="string" && /^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value);

async function ensureDirectory(path:string):Promise<string> {
  await mkdir(path,{recursive:true,mode:0o700});
  const info=await lstat(path);
  const canonical=await realpath(path);
  if(!info.isDirectory() || info.isSymbolicLink() || canonical!==resolve(path))throw new Error("Managed repository storage must be a canonical directory without symlinks.");
  await chmod(path,0o700);
  return canonical;
}

async function acquireLock(path:string):Promise<()=>Promise<void>> {
  const deadline=Date.now()+30_000;
  while(Date.now()<deadline) {
    try {
      const file=await open(path,"wx",0o600);
      await file.writeFile(String(process.pid));await file.sync();await file.close();
      return async()=>{await unlink(path).catch(error=>{if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;});};
    } catch(error) {
      const code=(error as NodeJS.ErrnoException).code;
      if(code!=="EEXIST")throw error;
      const info=await lstat(path).catch(()=>undefined);
      if(info?.isSymbolicLink() || (info && !info.isFile()))throw new Error("Unsafe repository cache lock.");
      const value=info?await readFile(path,"utf8").catch(()=>""):"";
      const pid=Number(value.trim());
      if(Number.isInteger(pid) && pid>0 && pid!==process.pid) {
        try {process.kill(pid,0);} catch(e) {
          if((e as NodeJS.ErrnoException).code==="ESRCH") {await unlink(path).catch(()=>{});continue;}
        }
      }
      await new Promise(resolve=>setTimeout(resolve,100));
    }
  }
  throw new Error("Repository cache is busy. Retry after the active repository operation finishes.");
}

async function worktreeGitDirectory(workspace:string,cache:string):Promise<string> {
  const pointer=join(workspace,".git");
  const info=await lstat(pointer);
  if(!info.isFile() || info.isSymbolicLink())throw new Error("Task worktree Git pointer is invalid.");
  const contents=await readFile(pointer,"utf8");
  const match=contents.match(/^gitdir: (.+)\r?\n?$/);
  if(!match)throw new Error("Task worktree Git pointer is invalid.");
  const gitdir=await realpath(resolve(workspace,match[1]));
  const worktrees=await realpath(join(cache,"worktrees"));
  if(!gitdir.startsWith(worktrees+sep) || relative(worktrees,gitdir).split(sep).length!==1)throw new Error("Task worktree metadata escaped its managed repository.");
  const gitInfo=await lstat(gitdir);
  if(!gitInfo.isDirectory() || gitInfo.isSymbolicLink())throw new Error("Task worktree metadata is invalid.");
  if(await realpath(join(gitdir,"..",".."))!==await realpath(cache))throw new Error("Task worktree points at a different managed repository.");
  return gitdir;
}

async function readMarker(workspace:string,cache:string):Promise<Marker> {
  const gitdir=await worktreeGitDirectory(workspace,cache);
  const path=join(gitdir,"orchestrator.json");
  const info=await lstat(path);
  if(!info.isFile() || info.isSymbolicLink() || (info.mode&0o077)!==0)throw new Error("Task worktree marker is unsafe.");
  const marker=JSON.parse(await readFile(path,"utf8")) as Marker;
  if(!validId(marker.run) || !validId(marker.project) || !Number.isInteger(marker.lifecycle) || marker.lifecycle<1 || !validRepository(marker.repository) || !validBranch(marker.base_branch) || !validBranch(marker.branch) || !validSHA(marker.baseline))throw new Error("Task worktree marker is invalid.");
  return marker;
}

async function workspaceCache(workspace:string):Promise<string> {
  const pointer=await readFile(join(workspace,".git"),"utf8");
  const match=pointer.match(/^gitdir: (.+)\r?\n?$/);
  if(!match)throw new Error("Task worktree Git pointer is invalid.");
  const gitdir=await realpath(resolve(workspace,match[1]));
  return realpath(join(gitdir,"..",".."));
}

export class RepositoryWorkspace {
  private readonly remoteURL:(repository:string)=>string;
  private readonly runCommand:typeof command;

  constructor(options:Options={}) {
    this.remoteURL=options.remoteURL??(repository=>`https://github.com/${repository}.git`);
    this.runCommand=options.runCommand??command;
  }

  async prepare(root:string,lease:Lease,credential:GitHubCredential):Promise<{path:string;branch:string;baseline:string;gitDir:string;commonDir:string}> {
    const projectId=lease.project_id;
    const repository=lease.snapshot?.repository;
    const baseBranch=lease.snapshot?.base_branch;
    if(!isAbsolute(root) || !validId(lease.id) || !validId(projectId) || !Number.isInteger(lease.lifecycle) || lease.lifecycle<1 || !validRepository(repository) || !validBranch(baseBranch))throw new Error("Task repository snapshot is invalid.");
    const dataRoot=await ensureDirectory(root);
    const repositories=await ensureDirectory(join(dataRoot,"repositories"));
    const workspaces=await ensureDirectory(join(dataRoot,"workspaces"));
    const cacheKey=createHash("sha256").update(repository).digest("hex").slice(0,16);
    const cache=join(repositories,`${projectId}-${cacheKey}`);
    const workspace=join(workspaces,`${lease.id}-${lease.lifecycle}`);
    const branch=`task/${lease.id}`;
    const remote=this.remoteURL(repository);
    const release=await acquireLock(cache+".lock");
    let stage="credential_setup";
    try {
      return await withGitHubCredential(dataRoot,credential,async env=>{
        const git=(args:string[],cwd?:string)=>this.runCommand("git",args,{cwd,env,timeout:120_000});
        stage="cache_inspection";
        let cacheInfo=await lstat(cache).catch(error=>{if((error as NodeJS.ErrnoException).code==="ENOENT")return undefined;throw error;});
        if(cacheInfo) {
          if(!cacheInfo.isDirectory() || cacheInfo.isSymbolicLink() || await realpath(cache)!==cache)throw new Error("Managed repository cache is unsafe.");
          if((await git(["--git-dir",cache,"rev-parse","--is-bare-repository"])).output!=="true")throw new Error("Managed repository cache is invalid.");
          const existing=(await git(["--git-dir",cache,"remote","get-url","origin"])).output;
          if(existing!==remote)throw new Error("Managed repository cache does not match the selected repository.");
        } else {
          stage="cache_clone";
          await git(["-c","core.hooksPath=/dev/null","clone","--bare","--template=","--",remote,cache]);
          cacheInfo=await lstat(cache);
          if(!cacheInfo.isDirectory() || cacheInfo.isSymbolicLink())throw new Error("Repository checkout did not create a safe cache.");
          await chmod(cache,0o700);
        }
        stage="base_fetch";
        await git(["--git-dir",cache,"-c","core.hooksPath=/dev/null","fetch","--prune","origin",`+refs/heads/${baseBranch}:refs/remotes/origin/${baseBranch}`]);
        const baseline=(await git(["--git-dir",cache,"rev-parse",`refs/remotes/origin/${baseBranch}^{commit}`])).output;
        if(!validSHA(baseline))throw new Error("Selected base branch does not resolve to a commit.");

        stage="workspace_inspection";
        const existingWorkspace=await lstat(workspace).catch(error=>{if((error as NodeJS.ErrnoException).code==="ENOENT")return undefined;throw error;});
        if(existingWorkspace) {
          if(!existingWorkspace.isDirectory() || existingWorkspace.isSymbolicLink() || await realpath(workspace)!==workspace)throw new Error("Existing task worktree is unsafe.");
          const gitdir=await worktreeGitDirectory(workspace,cache);
          const markerPath=join(gitdir,"orchestrator.json");
          const markerInfo=await lstat(markerPath).catch(error=>{
            if((error as NodeJS.ErrnoException).code==="ENOENT")return undefined;
            throw error;
          });
          const marker=markerInfo
            ? await readMarker(workspace,cache)
            : await this.recoverIncompleteWorktree(git,workspace,cache,lease,repository,baseBranch,baseline,branch,credential,gitdir);
          if(marker.run!==lease.id || marker.lifecycle!==lease.lifecycle || marker.project!==projectId || marker.repository!==repository || marker.base_branch!==baseBranch || marker.branch!==branch || !validSHA(marker.baseline))throw new Error("Existing task worktree identity does not match this lease.");
          return {path:workspace,branch,baseline:marker.baseline,gitDir:gitdir,commonDir:cache};
        }

        stage="workspace_creation";
        await git(["--git-dir",cache,"worktree","add","--force","--detach",workspace,baseline]);
        await git(["-C",workspace,"-c","core.hooksPath=/dev/null","switch","-C",branch,"--ignore-other-worktrees",baseline]);
        await git(["-C",workspace,"config","user.name",credential.author_name]);
        await git(["-C",workspace,"config","user.email",credential.author_email]);
        await git(["-C",workspace,"config","core.hooksPath","/dev/null"]);
        const gitdir=await worktreeGitDirectory(workspace,cache);
        await writeFile(join(gitdir,"orchestrator.json"),JSON.stringify({run:lease.id,lifecycle:lease.lifecycle,project:projectId,repository,base_branch:baseBranch,baseline,branch} satisfies Marker),{mode:0o600,flag:"wx"});
        return {path:workspace,branch,baseline,gitDir:gitdir,commonDir:cache};
      });
    } catch(error) {
      if(error instanceof GitHubCredentialFailure) {
        console.error(`Repository preparation failed at ${stage}: ${error.reason}.`);
        throw new RepositoryPreparationFailure("workspace_setup_failed");
      }
      if(error instanceof CommandFailure) {
        const reason=error.reason;
        const category:RepositoryFailureCategory=reason==="access_denied"?"github_permission_denied":reason==="network"?"github_unavailable":reason==="missing_ref"?"base_branch_missing":"workspace_setup_failed";
        console.error(`Repository preparation failed at ${stage}: ${reason}.`);
        throw new RepositoryPreparationFailure(category);
      }
      const code=error && typeof error==="object" && "code" in error && typeof error.code==="string" && /^[A-Z0-9_]+$/.test(error.code) ? ` (${error.code})` : "";
      console.error(`Repository preparation failed at ${stage}: local workspace error${code}.`);
      throw error instanceof Error && /Task repository|Managed repository|Selected base|Existing task|Task worktree/.test(error.message)
        ? error
        : new RepositoryPreparationFailure("workspace_setup_failed");
    } finally {
      await release();
    }
  }

  private async recoverIncompleteWorktree(
    git:(args:string[],cwd?:string)=>Promise<{output:string;code:number}>,
    workspace:string,
    cache:string,
    lease:Lease,
    repository:string,
    baseBranch:string,
    baseline:string,
    branch:string,
    credential:GitHubCredential,
    gitdir:string
  ):Promise<Marker> {
    const listing=(await git(["--git-dir",cache,"worktree","list","--porcelain"])).output;
    if(!listing.split("\n").some(line=>line==="worktree "+workspace))throw new Error("Unmarked task workspace is not registered in its managed repository.");
    if((await git(["-C",workspace,"rev-parse","--show-toplevel"])).output!==workspace)throw new Error("Unmarked task workspace root does not match its managed path.");
    if((await git(["-C",workspace,"rev-parse","HEAD"])).output!==baseline)throw new Error("Unmarked task workspace has changes and needs manual recovery.");
    const status=await git(["-C",workspace,"-c","core.fsmonitor=false","-c","core.untrackedCache=false","status","--porcelain","--untracked-files=all"]);
    if(status.output)throw new Error("Existing task workspace has changes and needs manual recovery.");
    await git(["-C",workspace,"-c","core.hooksPath=/dev/null","switch","-C",branch,"--ignore-other-worktrees",baseline]);
    await git(["-C",workspace,"config","user.name",credential.author_name]);
    await git(["-C",workspace,"config","user.email",credential.author_email]);
    await git(["-C",workspace,"config","core.hooksPath","/dev/null"]);
    const marker:Marker={run:lease.id,lifecycle:lease.lifecycle,project:lease.project_id!,repository,base_branch:baseBranch,baseline,branch};
    await writeFile(join(gitdir,"orchestrator.json"),JSON.stringify(marker),{mode:0o600,flag:"wx"});
    return marker;
  }

  async writeProjectInstructions(workspace:string,instructions:unknown):Promise<string|undefined> {
    if(typeof instructions!=="string" || Buffer.byteLength(instructions,"utf8")>32_000)throw new Error("Project instructions snapshot is invalid.");
    const canonical=await realpath(workspace);
    if(!isAbsolute(workspace) || canonical!==resolve(workspace))throw new Error("Task worktree path must be canonical.");
    const pointer=await readFile(join(canonical,".git"),"utf8");
    const match=pointer.match(/^gitdir: (.+)\r?\n?$/);
    if(!match)throw new Error("Task worktree Git pointer is invalid.");
    const gitdir=await realpath(resolve(canonical,match[1]));
    const cache=dirname(dirname(gitdir));
    const marker=await readMarker(canonical,cache);
    const target=join(canonical,`.dev-orchestrator-instructions-${marker.run}-${marker.lifecycle}.md`);
    const release=await acquireLock(cache+".lock");
    try {
      const existing=await lstat(target).catch(error=>{if((error as NodeJS.ErrnoException).code==="ENOENT")return undefined;throw error;});
      if(existing?.isSymbolicLink() || (existing && !existing.isFile()))throw new Error("Project instructions target is unsafe.");
      if(instructions==="") {
        if(existing)await unlink(target);
        return undefined;
      }
      if(existing) {
        if(await readFile(target,"utf8")!==instructions)throw new Error("Project instructions target already exists with different content.");
        return target;
      }
      const excludeDirPath=join(cache,"info");
      await mkdir(excludeDirPath,{recursive:true,mode:0o700});
      const excludeDir=await realpath(excludeDirPath);
      if(!excludeDir.startsWith(cache+sep))throw new Error("Worktree ignore metadata escaped its Git directory.");
      const excludeDirInfo=await lstat(excludeDirPath);
      if(!excludeDirInfo.isDirectory() || excludeDirInfo.isSymbolicLink())throw new Error("Worktree ignore metadata is unsafe.");
      const excludePath=join(excludeDir,"exclude");
      await writeFile(excludePath,"",{encoding:"utf8",mode:0o600,flag:"wx"}).catch(error=>{
        if((error as NodeJS.ErrnoException).code!=="EEXIST")throw error;
      });
      const excludeInfo=await lstat(excludePath);
      if(!excludeInfo.isFile() || excludeInfo.isSymbolicLink())throw new Error("Worktree ignore metadata is unsafe.");
      const exclude=await readFile(excludePath,"utf8");
      const rule=`/${basename(target)}`;
      if(!exclude.split(/\r?\n/).includes(rule)) {
        const excludeTemp=join(excludeDir,`.exclude-${randomUUID()}`);
        try {
          await writeFile(excludeTemp,exclude+(exclude.endsWith("\n")||exclude===""?"":"\n")+rule+"\n",{encoding:"utf8",mode:0o600,flag:"wx"});
          await rename(excludeTemp,excludePath);
        } catch(error) {
          await unlink(excludeTemp).catch(()=>{});
          throw error;
        }
      }
      const temporary=join(canonical,`.instructions-${randomUUID()}`);
      try {
        await writeFile(temporary,instructions,{encoding:"utf8",mode:0o600,flag:"wx"});
        await chmod(temporary,0o600);
        await rename(temporary,target);
        return target;
      } catch(error) {
        await unlink(temporary).catch(()=>{});
        throw error;
      }
    } finally {await release();}
  }

  async markTerminal(workspace:string,outcome:"success"|"failure"):Promise<void> {
    const canonical=await realpath(workspace);
    if(!isAbsolute(workspace) || canonical!==resolve(workspace))throw new Error("Task worktree path must be canonical.");
    const cache=await workspaceCache(canonical);
    const gitdir=await worktreeGitDirectory(canonical,cache);
    await readMarker(canonical,cache);
    const terminalPath=join(gitdir,"terminal.json");
    const existing=await lstat(terminalPath).catch(error=>{if((error as NodeJS.ErrnoException).code==="ENOENT")return undefined;throw error;});
    if(existing) {
      if(!existing.isFile() || existing.isSymbolicLink() || (existing.mode&0o077)!==0)throw new Error("Task terminal marker is unsafe.");
      const previous=JSON.parse(await readFile(terminalPath,"utf8")) as {outcome?:unknown};
      if(previous.outcome!==outcome)throw new Error("Task terminal outcome changed unexpectedly.");
      return;
    }
    await writeFile(terminalPath,JSON.stringify({outcome,recorded_at:Date.now()}),{mode:0o600,flag:"wx"});
  }

  async excludeRuntimeFiles(workspace: string): Promise<void> {
    const cache = await workspaceCache(workspace);
    await readMarker(workspace, cache);
    const release = await acquireLock(cache + ".lock");
    try {
      const directory = join(cache, "info");
      await ensureDirectory(directory);
      const path = join(directory, "exclude");
      const info = await lstat(path).catch(error => { if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined; throw error; });
      if (info && (!info.isFile() || info.isSymbolicLink() || info.size > 1_048_576)) throw new Error("Unsafe runtime exclude metadata.");
      const current = info ? await readFile(path, "utf8") : "";
      const rules = ["/node_modules/", "/.dev-orchestrator-cache/", "/.dev-orchestrator-context/"].filter(rule => !current.split(/\r?\n/).includes(rule));
      if (rules.length) await writeFile(path, current + "\n" + rules.join("\n") + "\n", { mode: 0o600 });
    } finally { await release(); }
  }

  async cleanupExpired(root:string,protectedWorkspace?:string,now=Date.now()):Promise<number> {
    const canonicalRoot=await ensureDirectory(root);
    const workspacesRoot=join(canonicalRoot,"workspaces");
    const entries=await readdir(workspacesRoot,{withFileTypes:true}).catch(error=>{
      if((error as NodeJS.ErrnoException).code==="ENOENT")return [];
      throw error;
    });
    let removed=0;
    for(const entry of entries) {
      if(!entry.isDirectory() || entry.isSymbolicLink())continue;
      const workspace=join(workspacesRoot,entry.name);
      if(workspace===protectedWorkspace)continue;
      try {
        if(await realpath(workspace)!==workspace)continue;
        const cache=await workspaceCache(workspace);
        const marker=await readMarker(workspace,cache);
        if(entry.name!==`${marker.run}-${marker.lifecycle}`)continue;
        const terminalPath=join(await worktreeGitDirectory(workspace,cache),"terminal.json");
        const terminalInfo=await lstat(terminalPath);
        if(!terminalInfo.isFile() || terminalInfo.isSymbolicLink() || (terminalInfo.mode&0o077)!==0)continue;
        const terminal=JSON.parse(await readFile(terminalPath,"utf8")) as {outcome?:unknown;recorded_at?:unknown};
        if(!["success","failure"].includes(String(terminal.outcome)) || typeof terminal.recorded_at!=="number")continue;
        const retention=terminal.outcome==="success"?24*60*60_000:7*24*60*60_000;
        if(now-terminal.recorded_at<retention)continue;
        if(await realpath(cache)!==cache)continue;
        const status=await this.runCommand(
          "git",
          ["-C",workspace,"-c","core.hooksPath=/dev/null","-c","core.attributesFile=/dev/null","status","--porcelain","--untracked-files=all"],
          {env:{PATH:process.env.PATH,HOME:process.env.HOME,GIT_CONFIG_NOSYSTEM:"1",GIT_CONFIG_GLOBAL:"/dev/null"},timeout:30_000}
        );
        if(status.output.trim()!=="")continue;
        const release=await acquireLock(cache+".lock");
        try {
          await this.runCommand("git",["--git-dir",cache,"-c","core.hooksPath=/dev/null","worktree","remove","--force",workspace],{env:{PATH:process.env.PATH,HOME:process.env.HOME,GIT_CONFIG_NOSYSTEM:"1",GIT_CONFIG_GLOBAL:"/dev/null"},timeout:30_000});
          await rm(workspace,{recursive:true,force:true});
          removed++;
        } finally {await release();}
      } catch { /* Unknown or unsafe worktrees are retained for manual recovery. */ }
    }
    return removed;
  }
}
