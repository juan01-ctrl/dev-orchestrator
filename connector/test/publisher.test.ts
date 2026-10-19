import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { Publisher } from "../src/publisher.ts";

test("publisher status never runs malicious workspace hooks or Git configuration",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-publisher-"));
  try {
    const workspace=join(root,"workspace");await mkdir(workspace);
    const git=(args:string[])=>execFileSync("git",["-C",workspace,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
    git(["init","-b","main"]);git(["config","user.name","Test"]);git(["config","user.email","test@example.test"]);
    await writeFile(join(workspace,"README.md"),"one\n");git(["add","README.md"]);git(["commit","-m","initial"]);
    const baseline=git(["rev-parse","HEAD"]);git(["switch","-c","task/run-id"]);
    const malicious=join(root,"executed");
    git(["config","core.fsmonitor",`echo bad > '${malicious}'`]);
    git(["config","core.hooksPath",root]);
    await writeFile(join(root,"pre-push"),`#!/bin/sh\necho bad > '${malicious}'\n`,{mode:0o755});
    const publisher=new Publisher({workspace,repository:"acme/app",baseBranch:"main",branch:"task/run-id",baseline});
    assert.deepEqual(await publisher.status(),{changed:false,commit:baseline});
    await assert.rejects(readFile(malicious));
    git(["config","--unset","core.fsmonitor"]);
    await writeFile(join(workspace,"README.md"),"two\n");
    await assert.rejects(publisher.status(),/Uncommitted/);
  } finally {await rm(root,{recursive:true,force:true});}
});
