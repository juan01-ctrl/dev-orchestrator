import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { access, mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { withGitHubCredential } from "../src/git-credential.ts";

const author={expires_at:"2099-01-01T00:00:00Z",author_name:"test-app[bot]",author_email:"12345+test-app[bot]@users.noreply.github.com"};

test("Git askpass accepts a punctuated token without embedding it in script or environment",async()=>{
  const root=await mkdtemp(join(tmpdir(),"orchestrator-credential-"));
  const token="ghs_test.'$(printf injected)+/=";
  let helper="";
  try {
    await withGitHubCredential(root,{...author,token},async env=>{
      helper=env.GIT_ASKPASS!;
      assert.equal(Object.values(env).some(value=>value?.includes(token)),false);
      assert.equal((await readFile(helper,"utf8")).includes(token),false);
      assert.equal(execFileSync(helper,["Password for 'https://github.com':"],{env:{...env,PATH:""},encoding:"utf8"}),token+"\n");
      assert.equal((await stat(env.ORCHESTRATOR_GITHUB_TOKEN_FILE!)).mode&0o777,0o600);
    });
    await assert.rejects(access(helper));
  } finally {await rm(root,{recursive:true,force:true});}
});
