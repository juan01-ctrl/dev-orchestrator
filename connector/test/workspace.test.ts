import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, symlink, writeFile, rm, realpath, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { validateMapping, prepareWorkspace, writeProjectInstructions } from "../src/workspace.ts";

test("canonical roots reject symlink escapes and source checkout reuse", async () => {
  const root=await mkdtemp(join(tmpdir(),"orchestrator-workspace-"));
  try {
    const source=join(root,"source"),workspaces=join(root,"workspaces");
    await mkdir(source); await mkdir(workspaces);
    await symlink(source,join(root,"alias"));
    const config={projectId:"11111111-1111-4111-8111-111111111111",repository:"acme/app",baseBranch:"main",source,workspaceRoot:workspaces};
    await assert.rejects(validateMapping({...config,workspaceRoot:join(root,"alias")}));
    await assert.rejects(validateMapping({...config,workspaceRoot:source}));
    await assert.rejects(validateMapping({...config,repository:"../../app"}));
  } finally {await rm(root,{recursive:true,force:true});}
});

test("task checkouts are isolated and retries preserve their committed work", async () => {
  const root=await realpath(await mkdtemp(join(tmpdir(),"orchestrator-git-")));
  try {
    const source=join(root,"source"),workspaces=join(root,"workspaces");
    await mkdir(source); await mkdir(workspaces);
    const git=(args:string[])=>execFileSync("git",["-C",source,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
    git(["init","-b","main"]); git(["config","user.name","Test"]);git(["config","user.email","test@example.test"]);
    await writeFile(join(source,"README.md"),"source\n");git(["add","README.md"]);git(["commit","-m","initial"]);
    git(["remote","add","origin","https://github.com/acme/app.git"]);
    const mapping={projectId:"11111111-1111-4111-8111-111111111111",repository:"acme/app",baseBranch:"main",source,workspaceRoot:workspaces};
    const lease={id:"22222222-2222-4222-8222-222222222222",generation:1,lifecycle:1,project_id:mapping.projectId,snapshot:{repository:"acme/app",base_branch:"main"}};
    const prepared=await prepareWorkspace(mapping,lease);
    assert.notEqual(prepared.path,source);
    await writeFile(join(prepared.path,"preserved.txt"),"work\n");
    const retry=await prepareWorkspace(mapping,{...lease,generation:2});
    assert.equal(retry.path,prepared.path);
    assert.equal(git(["status","--porcelain"]),"");
    await assert.rejects(prepareWorkspace(mapping,{...lease,id:"../escape"}));
  } finally {await rm(root,{recursive:true,force:true});}
});

test("project instructions stay private to task metadata and outside the Git diff", async () => {
  const root=await realpath(await mkdtemp(join(tmpdir(),"orchestrator-instructions-")));
  try {
    const source=join(root,"source"),workspaces=join(root,"workspaces");
    await mkdir(source); await mkdir(workspaces);
    const git=(args:string[])=>execFileSync("git",["-C",source,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
    git(["init","-b","main"]);git(["config","user.name","Test"]);git(["config","user.email","test@example.test"]);
    await writeFile(join(source,"WORKFLOW.md"),"repository-owned guidance\n");
    await writeFile(join(source,"README.md"),"source\n");git(["add","README.md","WORKFLOW.md"]);git(["commit","-m","initial"]);
    git(["remote","add","origin","https://github.com/acme/app.git"]);
    const mapping={projectId:"11111111-1111-4111-8111-111111111111",repository:"acme/app",baseBranch:"main",source,workspaceRoot:workspaces};
    const lease={id:"22222222-2222-4222-8222-222222222222",generation:1,lifecycle:1,project_id:mapping.projectId,snapshot:{repository:"acme/app",base_branch:"main"}};
    const prepared=await prepareWorkspace(mapping,lease);
    const contents="# Team guidance\nKeep changes focused.\n";

    assert.equal(await writeProjectInstructions(prepared.path,contents),join(prepared.path,".git","WORKFLOW.md"));
    assert.equal(await readFile(join(prepared.path,".git","WORKFLOW.md"),"utf8"),contents);
    assert.equal((await stat(join(prepared.path,".git","WORKFLOW.md"))).mode & 0o777,0o600);
    assert.equal(await readFile(join(prepared.path,"WORKFLOW.md"),"utf8"),"repository-owned guidance\n");
    assert.equal(await writeProjectInstructions(prepared.path,""),undefined);
    await assert.rejects(writeProjectInstructions(prepared.path,42));
    await assert.rejects(writeProjectInstructions(prepared.path,"x".repeat(32_001)));
    assert.equal(execFileSync("git",["-C",prepared.path,"status","--porcelain"],{encoding:"utf8"}).trim(),"");
  } finally {await rm(root,{recursive:true,force:true});}
});
