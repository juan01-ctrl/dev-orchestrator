import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, readFile, realpath } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { RepositoryWorkspace } from "../src/repository.ts";

const projectId="11111111-1111-4111-8111-111111111111";
const lease=(id:string, lifecycle=1, repository="acme/app", base_branch="main")=>({
  id,generation:1,lifecycle,project_id:projectId,
  snapshot:{repository,base_branch,instructions:"# Team rules\n"}
});
const credential={token:"temporary-test-token",expires_at:"2099-01-01T00:00:00Z",author_name:"test-app[bot]",author_email:"12345+test-app[bot]@users.noreply.github.com"};

async function fixture() {
  const root=await realpath(await mkdtemp(join(tmpdir(),"orchestrator-repository-")));
  const source=join(root,"remote-source"),remote=join(root,"remote.git");
  await mkdir(source);await mkdir(remote);
  const git=(cwd:string,args:string[])=>execFileSync("git",["-C",cwd,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
  git(source,["init","-b","main"]);git(source,["config","user.name","Fixture"]);git(source,["config","user.email","fixture@example.test"]);
  await writeFile(join(source,"README.md"),"from github\n");git(source,["add","README.md"]);git(source,["commit","-m","initial"]);
  git(remote,["init","--bare"]);git(source,["remote","add","origin",remote]);git(source,["push","origin","main"]);
  return {root,remote,git};
}

test("bootstraps a managed repository cache and isolated task worktree without a local mapping",async()=>{
  const f=await fixture();
  try {
    const manager=new RepositoryWorkspace({remoteURL:()=>f.remote});
    const first=await manager.prepare(f.root,lease("22222222-2222-4222-8222-222222222222"),credential);
    const second=await manager.prepare(f.root,lease("33333333-3333-4333-8333-333333333333"),credential);
    assert.notEqual(first.path,second.path);
    assert.equal(first.branch,"task/22222222-2222-4222-8222-222222222222");
    assert.equal(await readFile(join(first.path,"README.md"),"utf8"),"from github\n");
    assert.equal(f.git(first.path,["config","user.name"]),credential.author_name);
    assert.equal(f.git(first.path,["config","user.email"]),credential.author_email);
    assert.equal(f.git(first.path,["config","remote.origin.url"]),f.remote);
    assert.equal(f.git(first.path,["status","--porcelain"]),"");
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("reuses the matching task lifecycle and rejects repository, branch, and marker mismatches",async()=>{
  const f=await fixture();
  try {
    const manager=new RepositoryWorkspace({remoteURL:()=>f.remote});
    const original=lease("22222222-2222-4222-8222-222222222222");
    const first=await manager.prepare(f.root,original,credential);
    const retry=await manager.prepare(f.root,{...original,generation:2},credential);
    assert.equal(retry.path,first.path);
    await assert.rejects(manager.prepare(f.root,{...original,snapshot:{repository:"acme/other",base_branch:"main"}},credential));
    await assert.rejects(manager.prepare(f.root,{...original,snapshot:{repository:"acme/app",base_branch:"develop"}},credential));
    const metadata=(await readFile(join(first.path,".git"),"utf8")).trim().replace(/^gitdir: /,"");
    await writeFile(join(resolve(first.path,metadata),"orchestrator.json"),JSON.stringify({run:"wrong"}));
    await assert.rejects(manager.prepare(f.root,original,credential),/identity|marker|workspace/i);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("keeps tokens out of cache remotes and stores instructions in private worktree metadata",async()=>{
  const f=await fixture();
  try {
    const manager=new RepositoryWorkspace({remoteURL:()=>f.remote});
    const prepared=await manager.prepare(f.root,lease("22222222-2222-4222-8222-222222222222"),credential);
    const instructions=await manager.writeProjectInstructions(prepared.path,"# Private rules\n");
    assert.equal(instructions,join(prepared.path,".dev-orchestrator-instructions-22222222-2222-4222-8222-222222222222-1.md"));
    assert.equal(await readFile(instructions!,"utf8"),"# Private rules\n");
    assert.equal(f.git(prepared.path,["check-ignore","-q",instructions!]),"");
    const cache=join(f.root,"repositories",`${projectId}-${createHash("sha256").update("acme/app").digest("hex").slice(0,16)}`);
    assert.equal(f.git(cache,["config","remote.origin.url"]),f.remote);
    assert.equal(f.git(prepared.path,["status","--porcelain"]),"");
    assert.equal(f.git(cache,["config","--get","user.name"]),credential.author_name);
    assert.equal(await readFile(join(prepared.path,".git"),"utf8").then(x=>x.includes(credential.token)),false);
    assert.equal(await manager.writeProjectInstructions(prepared.path,"# Private rules\n"),instructions);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("cleans only acknowledged terminal worktrees after their retention window",async()=>{
  const f=await fixture();
  try {
    const manager=new RepositoryWorkspace({remoteURL:()=>f.remote});
    const successful=await manager.prepare(f.root,lease("22222222-2222-4222-8222-222222222222"),credential);
    const failed=await manager.prepare(f.root,lease("33333333-3333-4333-8333-333333333333"),credential);
    const active=await manager.prepare(f.root,lease("44444444-4444-4444-8444-444444444444"),credential);
    await manager.markTerminal(successful.path,"success");
    await manager.markTerminal(failed.path,"failure");
    assert.equal(await manager.cleanupExpired(f.root,active.path,Date.now()+25*60*60_000),1);
    await assert.rejects(readFile(join(successful.path,"README.md")));
    assert.equal(await readFile(join(failed.path,"README.md"),"utf8"),"from github\n");
    assert.equal(await readFile(join(active.path,"README.md"),"utf8"),"from github\n");
    assert.equal(await manager.cleanupExpired(f.root,active.path,Date.now()+8*24*60*60_000),1);
    await assert.rejects(readFile(join(failed.path,"README.md")));
    assert.equal(await readFile(join(active.path,"README.md"),"utf8"),"from github\n");
  } finally {await rm(f.root,{recursive:true,force:true});}
});
