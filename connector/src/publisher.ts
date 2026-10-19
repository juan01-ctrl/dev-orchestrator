import { mkdtemp, readFile, writeFile, rm, realpath, lstat, access } from "node:fs/promises";
import { join, sep } from "node:path";
import { tmpdir } from "node:os";
import { command, cleanGitEnv } from "./process.ts";
import { validBranch, validRepository } from "./workspace.ts";

type Context={workspace:string;repository:string;baseBranch:string;branch:string;baseline:string};
const validSHA=(sha:string)=>/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(sha);

export class Publisher {
  readonly context: Context;
  constructor(context:Context) {
    if(!validRepository(context.repository) || !validBranch(context.branch) || !validBranch(context.baseBranch) || context.branch===context.baseBranch || !context.branch.startsWith("task/") || !validSHA(context.baseline))throw new Error("Invalid publication context.");
    this.context=context;
  }

  async status(signal?:AbortSignal):Promise<{changed:boolean;commit:string}> {
    return this.trusted(async(git,sha)=>{
      const uncommitted=await git(["diff","--no-ext-diff","--no-textconv","--quiet",sha,"--"],true);
      const untracked=await git(["ls-files","--others","--exclude-standard"]);
      if(uncommitted.code!==0 || untracked.output)throw new Error("Uncommitted changes remain. Codex must commit the task before publication.");
      const diff=await git(["diff","--no-ext-diff","--no-textconv","--quiet",this.context.baseline,sha,"--"],true);
      return {changed:diff.code===1,commit:sha};
    },signal);
  }

  async publish(title:string,body:string,signal?:AbortSignal):Promise<Record<string,string>> {
    if(!title.trim() || title.length>240 || body.length>64_000)throw new Error("Invalid PR metadata.");
    const status=await this.status(signal);
    if(!status.changed)throw new Error("No committed changes to publish.");
    return this.trusted(async(git,sha,temp)=>{
      await git(["-c","credential.helper=","-c","credential.helper=!gh auth git-credential","push","--no-verify",`https://github.com/${this.context.repository}.git`,`${sha}:refs/heads/${this.context.branch}`]);
      const gh=async(args:string[])=>command("gh",args,{cwd:temp,env:cleanGitEnv(),signal});
      const lookup=async()=>{
        const {output}=await gh(["pr","list","--repo",this.context.repository,"--head",this.context.branch,"--base",this.context.baseBranch,"--state","open","--json","url,headRefOid,headRefName,baseRefName"]);
        const list=JSON.parse(output);
        if(!Array.isArray(list))throw new Error("Invalid GitHub response.");
        return list[0];
      };
      let pr=await lookup();
      if(!pr){
        const bodyFile=join(temp,"body.md");await writeFile(bodyFile,body,{mode:0o600});
        await gh(["pr","create","--repo",this.context.repository,"--head",this.context.branch,"--base",this.context.baseBranch,"--title",title,"--body-file",bodyFile]);
        pr=await lookup();
      }
      if(pr?.headRefOid!==sha || pr?.headRefName!==this.context.branch || pr?.baseRefName!==this.context.baseBranch || !new RegExp(`^https://github\\.com/${this.context.repository.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")}/pull/[0-9]+$`).test(pr?.url??""))throw new Error("GitHub PR does not match the task commit.");
      return {repository:this.context.repository,branch:this.context.branch,base_branch:this.context.baseBranch,commit:sha,pr_url:pr.url};
    },signal);
  }

  private async trusted<T>(fn:(git:(args:string[],allowExitOne?:boolean)=>Promise<{output:string;code:number}>,sha:string,temp:string)=>Promise<T>,signal?:AbortSignal):Promise<T> {
    const workspace=await realpath(this.context.workspace);
    const gitDir=join(workspace,".git");
    const stat=await lstat(gitDir);
    const objects=await realpath(join(gitDir,"objects"));
    if(!stat.isDirectory() || stat.isSymbolicLink() || !objects.startsWith(gitDir+sep))throw new Error("Publication needs an internal Git object directory.");
    for(const forbidden of ["info/alternates","info/http-alternates"]) {
      try{await access(join(objects,forbidden));throw new Error("External Git object stores are not supported.");}
      catch(e){if((e as NodeJS.ErrnoException).code!=="ENOENT")throw e;}
    }
    const head=await readFile(join(gitDir,"HEAD"),"utf8");
    if(head.trim()!==`ref: refs/heads/${this.context.branch}`)throw new Error("Task branch changed unexpectedly.");
    const ref=join(gitDir,"refs","heads",this.context.branch);
    const resolved=await realpath(ref);
    if(!resolved.startsWith(gitDir+sep))throw new Error("Unsafe Git reference.");
    const sha=(await readFile(ref,"utf8")).trim();
    if(!validSHA(sha))throw new Error("Invalid task commit.");
    const temporary=await mkdtemp(join(tmpdir(),"dev-orchestrator-publish-"));
    try {
      const bare=join(temporary,"repo.git");
      await command("git",["init","--bare","--template=",bare],{signal});
      try {
        const shallow=await readFile(join(gitDir,"shallow"),"utf8");
        if(!shallow.trim().split("\n").every(validSHA))throw new Error("Invalid shallow boundary.");
        await writeFile(join(bare,"shallow"),shallow,{mode:0o600});
      } catch(e) {if((e as NodeJS.ErrnoException).code!=="ENOENT")throw e;}
      const env={...cleanGitEnv(),GIT_OBJECT_DIRECTORY:objects};
      const git=(args:string[],allowExitOne=false)=>command("git",["--git-dir",bare,"--work-tree",workspace,"-c","core.bare=false","-c","core.hooksPath=/dev/null",...args],{cwd:temporary,env,signal,allowExitOne});
      await git(["read-tree",sha]);
      return await fn(git,sha,temporary);
    } finally {await rm(temporary,{recursive:true,force:true});}
  }
}
