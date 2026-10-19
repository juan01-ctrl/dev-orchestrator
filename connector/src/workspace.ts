import { lstat, realpath, mkdir, readFile, writeFile, chmod, rename, unlink } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { join, relative, isAbsolute, sep } from "node:path";
import { command, readAuthor } from "./process.ts";
import type { Mapping, Lease } from "./types.ts";

export const validBranch=(s:unknown):s is string=>typeof s==="string" && s.length<=200 && /^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(s) && !s.includes("..") && !s.includes("//") && s.split("/").every(p=>p && !p.startsWith(".") && !p.endsWith(".") && !p.endsWith(".lock"));
export const validRepository=(s:unknown):s is string=>typeof s==="string" && /^[A-Za-z0-9][A-Za-z0-9_-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(s) && !s.includes("..") && !s.endsWith(".git");
const validId=(s:unknown):s is string=>typeof s==="string" && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(s);

export async function canonicalDirectory(path:string):Promise<string> {
  if(!isAbsolute(path))throw new Error("Use absolute filesystem paths.");
  const stat=await lstat(path);
  const canonical=await realpath(path);
  if(!stat.isDirectory() || stat.isSymbolicLink() || canonical!==path.replace(/\/$/,""))throw new Error("Directory must be canonical and must not contain symlinks.");
  return canonical;
}

export async function validateMapping(mapping:Mapping):Promise<Mapping> {
  if(!validId(mapping.projectId) || !validRepository(mapping.repository) || !validBranch(mapping.baseBranch))throw new Error("Invalid local project authorization.");
  const source=await canonicalDirectory(mapping.source);
  const workspaceRoot=await canonicalDirectory(mapping.workspaceRoot);
  const descendant=(parent:string,child:string)=>{const path=relative(parent,child);return path==="" || (!path.startsWith(".."+sep) && path!==".." && !isAbsolute(path));};
  if(descendant(source,workspaceRoot) || descendant(workspaceRoot,source))throw new Error("Task workspaces must be separate from the source checkout.");
  const origin=(await command("git",["-C",source,"config","--local","--get","remote.origin.url"])).output;
  if(![`https://github.com/${mapping.repository}.git`,`https://github.com/${mapping.repository}`,`git@github.com:${mapping.repository}.git`].includes(origin))throw new Error("Source repository does not match the approved GitHub repository.");
  return {...mapping,source,workspaceRoot};
}

export async function prepareWorkspace(mapping:Mapping,lease:Lease):Promise<{path:string;branch:string;baseline:string}> {
  mapping=await validateMapping(mapping);
  if(!validId(lease.id) || !Number.isInteger(lease.lifecycle) || lease.lifecycle<1 || lease.project_id!==mapping.projectId || lease.snapshot?.repository!==mapping.repository || lease.snapshot?.base_branch!==mapping.baseBranch)throw new Error("Task does not match local project authorization.");
  const path=join(mapping.workspaceRoot,`${lease.id}-${lease.lifecycle}`);
  const branch=`task/${lease.id}`;
  try {
    await canonicalDirectory(path);
    const marker=JSON.parse(await readFile(join(path,".git","orchestrator.json"),"utf8"));
    if(marker.run!==lease.id || marker.lifecycle!==lease.lifecycle || marker.repository!==mapping.repository || !/^[a-f0-9]{40,64}$/.test(marker.baseline))throw new Error("Workspace identity mismatch.");
    return {path,branch,baseline:marker.baseline};
  } catch(error) {
    if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;
  }
  // mkdir without recursive prevents accidentally reusing an incomplete checkout.
  await mkdir(path,{mode:0o700});
  try {
    await command("git",["-c","core.hooksPath=/dev/null","clone","--no-local","--no-hardlinks","--template=","--branch",mapping.baseBranch,"--",mapping.source,path]);
    const baseline=(await command("git",["-C",path,"rev-parse","HEAD"])).output;
    await command("git",["-C",path,"-c","core.hooksPath=/dev/null","switch","-c",branch]);
    const {name,email}=await readAuthor(mapping.source);
    await command("git",["-C",path,"config","user.name",name]);
    await command("git",["-C",path,"config","user.email",email]);
    await writeFile(join(path,".git","orchestrator.json"),JSON.stringify({run:lease.id,lifecycle:lease.lifecycle,repository:mapping.repository,baseline}),{mode:0o600,flag:"wx"});
    return {path,branch,baseline};
  } catch { throw new Error("Workspace setup failed. Preserved the partial checkout for inspection; check the source branch and Git identity."); }
}

export async function writeProjectInstructions(workspace:string,instructions:unknown):Promise<string|undefined> {
  if(typeof instructions!=="string")throw new Error("Project instructions snapshot must be text.");
  if(Buffer.byteLength(instructions,"utf8")>32_000)throw new Error("Project instructions snapshot exceeds the size limit.");
  if(instructions==="")return undefined;
  if(!isAbsolute(workspace))throw new Error("Task checkout path must be absolute.");

  const canonical=await realpath(workspace);
  if(canonical!==workspace.replace(/\/$/,""))throw new Error("Task checkout path must be canonical.");
  const gitDirectory=join(canonical,".git");
  const gitStat=await lstat(gitDirectory);
  if(!gitStat.isDirectory() || gitStat.isSymbolicLink())throw new Error("Task checkout Git metadata is not a real directory.");

  const target=join(gitDirectory,"WORKFLOW.md");
  try {
    if((await lstat(target)).isSymbolicLink())throw new Error("Project instructions target must not be a symlink.");
  } catch(error) {
    if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;
  }
  const temporary=join(gitDirectory,`.instructions-${randomUUID()}`);
  try {
    await writeFile(temporary,instructions,{encoding:"utf8",mode:0o600,flag:"wx"});
    await chmod(temporary,0o600);
    await rename(temporary,target);
  } catch(error) {
    await unlink(temporary).catch(()=>{});
    throw error;
  }
  return target;
}
