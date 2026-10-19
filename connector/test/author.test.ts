import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { readAuthor } from "../src/process.ts";

test("a normal global Git author can be read without modifying global configuration",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-author-"));
  try {
    execFileSync("git",["init",root],{stdio:"ignore"});
    const globalFile=join(root,"fixture-global-config");
    execFileSync("git",["config","--file",globalFile,"user.name","Global Test Author"]);
    execFileSync("git",["config","--file",globalFile,"user.email","author@example.test"]);
    assert.deepEqual(await readAuthor(root,{PATH:process.env.PATH,HOME:process.env.HOME,GIT_CONFIG_GLOBAL:globalFile,GIT_CONFIG_NOSYSTEM:"1"}),{name:"Global Test Author",email:"author@example.test"});
  } finally {await rm(root,{recursive:true,force:true});}
});
