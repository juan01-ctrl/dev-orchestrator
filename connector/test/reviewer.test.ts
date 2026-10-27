import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm, realpath, access, chmod } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { normalizeReview, reviewPrompt, reviewMatches, reviewCandidate } from "../src/reviewer.ts";
import { Publisher } from "../src/publisher.ts";
import { RepositoryWorkspace } from "../src/repository.ts";

const identity = { baseline: "a".repeat(40), commit: "b".repeat(40), generation: 2, task_digest: "c".repeat(64) };
const approved = { outcome: "completed", verdict: "approve", summary: "No actionable defects found", findings: [], limitations: ["Inspection only; no build executed"] };

test("independent review fails closed on malformed, inconclusive or contradictory findings", () => {
  assert.equal(normalizeReview(approved, identity, ["src/app.ts"]).verdict, "approve");
  const important = { severity: "important", path: "src/app.ts", line: 3, description: "Null input crashes", evidence: "Dereference occurs before the guard" };
  assert.equal(normalizeReview({ ...approved, findings: [important] }, identity, ["src/app.ts"]).verdict, "request_changes");
  assert.equal(normalizeReview({ ...approved, verdict: "blocked" }, identity, []).verdict, "blocked");
  for (const value of [null, {}, { ...approved, verdict: "maybe" }, { ...approved, findings: "none" },
    {...approved,unexpected:"claim"},
    { ...approved, findings: [{ ...important, path: "../secret" }] },
    { ...approved, findings: [{ ...important, path: "absent.ts" }] },
    { ...approved, findings: [{ ...important, line: 0 }] }]) {
    assert.throws(() => normalizeReview(value, identity, ["src/app.ts"]));
  }
  assert.throws(()=>normalizeReview({...approved,findings:[important]},identity,["src/app.ts"],{"src/app.ts":1}));
  assert.throws(()=>normalizeReview({...approved,findings:[{...important,unexpected:"claim"}]},identity,["src/app.ts"]));
});

test("review approval is reusable only for the exact base, head, generation and task", () => {
  const review = normalizeReview(approved, identity, []);
  assert.equal(reviewMatches(review, identity), true);
  for (const patch of [{ commit: "d".repeat(40) }, { baseline: "d".repeat(40) }, { generation: 3 }, { task_digest: "d".repeat(64) }]) {
    assert.equal(reviewMatches(review, { ...identity, ...patch }), false);
  }
  assert.equal(reviewMatches({ ...review, verdict: "blocked" }, identity), false);
});

test("review input carries the approved request but not implementation persuasion", () => {
  const prompt = reviewPrompt({ title: "Add export", prompt: "CSV includes selected month", instructions: "Keep scope narrow", baseline: identity.baseline, commit: identity.commit, adjustment: "Use semicolons" });
  assert.match(prompt, /CSV includes selected month/);
  assert.match(prompt, /Use semicolons/);
  assert.match(prompt, /untrusted/i);
  assert.match(prompt, /independent/i);
  assert.doesNotMatch(prompt, /implementation summary|all tests passed|implementer believes/i);
});

test("inspection review receives candidate-bound executor checks without implementation claims", () => {
  const prompt = reviewPrompt({ title:"Dashboard", prompt:"Add filters", instructions:"", ...identity,
    executedChecks:[{command:"npm run check",status:"passed"},{command:"npm run test",status:"passed"}] });
  assert.match(prompt, /Connector-executed validation/);
  assert.match(prompt, new RegExp(identity.commit));
  assert.match(prompt, /"command":"npm run check","status":"passed"/);
  assert.match(prompt, /"command":"npm run test","status":"passed"/);
  assert.match(prompt, /do not block solely/i);
  assert.doesNotMatch(prompt, /implementation summary|implementer believes/i);
});

test("candidate review clone has independent objects, exact refs and no runtime files or remotes", async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), "review-isolation-test-")));
  const git = (cwd: string, args: string[]) => execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  try {
    const source = join(root, "source"), remote = join(root, "remote.git");
    await mkdir(source); git(source, ["init", "-b", "main"]); git(source, ["config", "user.name", "Test"]); git(source, ["config", "user.email", "test@example.test"]);
    await writeFile(join(source, "README.md"), "baseline\n"); git(source, ["add", "."]); git(source, ["commit", "-m", "baseline"]);
    git(root, ["init", "--bare", remote]); git(source, ["push", remote, "main"]);
    const workspace = await new RepositoryWorkspace({ remoteURL: () => remote }).prepare(root,
      { id: "22222222-2222-4222-8222-222222222222", project_id: "11111111-1111-4111-8111-111111111111", generation: 1, lifecycle: 1, snapshot: { repository: "acme/app", base_branch: "main" } },
      { token: "fixture", expires_at: "2099-01-01T00:00:00Z", author_name: "Test", author_email: "test@example.test" });
    await writeFile(join(workspace.path, "change.txt"), "candidate\n");
    const publisher = new Publisher({ workspace: workspace.path, repository: "acme/app", baseBranch: "main", branch: workspace.branch, baseline: workspace.baseline, gitDir: workspace.gitDir, commonDir: workspace.commonDir });
    const candidate = await publisher.commit("EVAL", { author_name: "Test", author_email: "test@example.test" });
    await writeFile(join(workspace.path, "implementation-notes.private"), "Persuasive self-review");
    let reviewPath = "";
    await publisher.reviewSnapshot(candidate.commit, async path => {
      reviewPath = path;
      assert.notEqual(path, workspace.path);
      assert.equal(git(path, ["rev-parse", "HEAD"]), candidate.commit);
      assert.equal(git(path, ["rev-parse", "refs/heads/review-base"]), workspace.baseline);
      assert.equal(git(path, ["remote"]), "");
      assert.equal(await readFile(join(path, "change.txt"), "utf8"), "candidate\n");
      await assert.rejects(access(join(path, "implementation-notes.private")));
      await assert.rejects(access(join(path, ".git/objects/info/alternates")));
      assert.notEqual(await realpath(join(path, ".git/objects")), await realpath(join(workspace.commonDir, "objects")));
    });
    await assert.rejects(access(reviewPath));
    await assert.rejects(publisher.reviewSnapshot("e".repeat(40), async () => {}), /changed|candidate|head/i);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("reviewer starts a fresh read-only no-network session without implementation history or publishing credentials", async () => {
  const root=await realpath(await mkdtemp(join(tmpdir(),"review-session-test-")));
  const git=(args:string[])=>execFileSync("git",["-C",root,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
  try {
    git(["init","-b","main"]);git(["config","user.name","Test"]);git(["config","user.email","test@example.test"]);
    await writeFile(join(root,"README.md"),"candidate\n");git(["add","README.md"]);git(["commit","-m","candidate"]);
    const head=git(["rev-parse","HEAD"]), observation=join(root,"observed.json"), binary=join(root,"fake-reviewer.mjs");
    await writeFile(binary,`#!/usr/bin/env node
import readline from 'node:readline';import {writeFileSync} from 'node:fs';
const send=o=>process.stdout.write(JSON.stringify(o)+'\\n');const observed={args:process.argv.slice(2),methods:[],publishToken:process.env.GITHUB_TOKEN??null,gitGlobal:process.env.GIT_CONFIG_GLOBAL,gitSystem:process.env.GIT_CONFIG_NOSYSTEM};
readline.createInterface({input:process.stdin}).on('line',line=>{const m=JSON.parse(line);
if(m.id==='review-permission'){observed.approval=m.result;writeFileSync(${JSON.stringify(observation)},JSON.stringify(observed));send({method:'item/completed',params:{threadId:'fresh-review-thread',item:{type:'agentMessage',text:JSON.stringify(${JSON.stringify(approved)})}}});return send({method:'turn/completed',params:{threadId:'fresh-review-thread',turn:{status:'completed'}}});}
if(!m.method)return;observed.methods.push(m.method);
if(m.method==='account/read')return send({id:m.id,result:{account:{type:'chatgpt'}}});
if(m.method==='thread/start'){observed.thread=m.params;return send({id:m.id,result:{thread:{id:'fresh-review-thread'}}});}
if(m.method==='turn/start'){if(m.params.input[0].text.includes('tamper-fixture'))writeFileSync('README.md','tampered');observed.turn=m.params;send({id:m.id,result:{}});return send({id:'review-permission',method:'item/commandExecution/requestApproval',params:{cwd:process.cwd(),command:'write protected file'}});}
if(m.id!==undefined)send({id:m.id,result:{data:[]}});
});`);
    await chmod(binary,0o755);
    const report=await reviewCandidate({...identity,baseline:head,commit:head,binary,workspace:root,sourceWorkspace:root,lease:{id:"run",generation:2,lifecycle:1,title:"Review task",prompt:"Original acceptance requirement",snapshot:{instructions:"Frozen guidance"}},executedChecks:[{command:"npm run check",status:"passed"}],model:"configured-model",signal:new AbortController().signal});
    assert.equal(report.verdict,"approve");
    const seen=JSON.parse(await readFile(observation,"utf8"));
    assert.equal(seen.publishToken,null);assert.ok(seen.methods.includes("thread/start"));assert.ok(!seen.methods.includes("thread/resume"));
    assert.equal(seen.approval.decision,"decline");
    assert.equal(seen.gitGlobal,"/dev/null");assert.equal(seen.gitSystem,"1");
    assert.ok(seen.args.includes("permissions.dev-orchestrator.network.enabled=false"));
    assert.ok(!seen.args.find((v:string)=>v.startsWith("permissions.dev-orchestrator.filesystem"))?.includes('="write"'));
    assert.equal(seen.thread.model,"configured-model");assert.match(seen.turn.input[0].text,/Original acceptance requirement/);
    assert.doesNotMatch(seen.turn.input[0].text,/No actionable defects found/);
    assert.match(seen.turn.input[0].text,/"command":"npm run check","status":"passed"/);
    await assert.rejects(reviewCandidate({...identity,baseline:head,commit:head,binary,workspace:root,sourceWorkspace:root,lease:{id:"run",generation:2,lifecycle:1,prompt:"tamper-fixture"},signal:new AbortController().signal}),/changed|modified|candidate/i);
  } finally {await rm(root,{recursive:true,force:true});}
});
