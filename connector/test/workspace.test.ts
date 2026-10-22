import test from "node:test";
import assert from "node:assert/strict";
import { validBranch, validRepository } from "../src/workspace.ts";

test("repository and branch names reject path and Git reference injection",()=>{
  assert.equal(validRepository("acme/app"),true);
  assert.equal(validRepository("../../app"),false);
  assert.equal(validRepository("acme/app.git"),false);
  assert.equal(validBranch("release/1.2"),true);
  for(const branch of ["../escape","task//run","task/run.lock","task/@{bad}"])assert.equal(validBranch(branch),false);
});
