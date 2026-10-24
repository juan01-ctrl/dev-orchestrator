import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, realpath, access } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { execFileSync } from "node:child_process";
import { RepositoryWorkspace } from "../src/repository.ts";
import { Publisher } from "../src/publisher.ts";
import { command } from "../src/process.ts";

const projectId="11111111-1111-4111-8111-111111111111";
const runId="22222222-2222-4222-8222-222222222222";
const credential={token:"short-lived-test-token",expires_at:"2099-01-01T00:00:00Z",author_name:"test-app[bot]",author_email:"12345+test-app[bot]@users.noreply.github.com"};

async function fixture(performCommit=true, branch=`task/${runId}`) {
  const root=await realpath(await mkdtemp(join(tmpdir(),"orchestrator-publisher-")));
  const source=join(root,"source"),remote=join(root,"remote.git");
  await mkdir(source);await mkdir(remote);
  const git=(cwd:string,args:string[])=>execFileSync("git",["-C",cwd,...args],{encoding:"utf8",stdio:["ignore","pipe","pipe"]}).trim();
  git(source,["init","-b","main"]);git(source,["config","user.name","Fixture"]);git(source,["config","user.email","fixture@example.test"]);
  await writeFile(join(source,"README.md"),"base\n");git(source,["add","README.md"]);git(source,["commit","-m","initial"]);
  git(remote,["init","--bare"]);git(source,["remote","add","origin",remote]);git(source,["push","origin","main"]);
  const repository=new RepositoryWorkspace({remoteURL:()=>remote});
  const lease={id:runId,project_id:projectId,generation:1,lifecycle:1,snapshot:{repository:"acme/app",base_branch:"main",task_branch:branch}};
  const workspace=await repository.prepare(root,lease,credential);
  await writeFile(join(workspace.path,"change.txt"),"task change\n");
  if(performCommit){git(workspace.path,["add","change.txt"]);git(workspace.path,["commit","-m","test: add task change"]);}
  return {root,remote,workspace,git};
}

const pullRequest=(sha:string)=>({
  state:"open",
  html_url:"https://github.com/acme/app/pull/17",
  head:{sha,ref:`task/${runId}`,repo:{full_name:"acme/app"}},
  base:{ref:"main",repo:{full_name:"acme/app"}}
});

test("publishes a lifecycle branch without a legacy-ref namespace collision",async()=>{
  const branch=`task-attempts/${runId}/attempt-1`;
  const f=await fixture(true,branch);
  try {
    const sha=f.git(f.workspace.path,["rev-parse","HEAD"]);
    const pr=pullRequest(sha);pr.head.ref=branch;
    const publisher=new Publisher({workspace:f.workspace.path,repository:"acme/app",baseBranch:"main",branch,baseline:f.workspace.baseline,gitDir:f.workspace.gitDir,commonDir:f.workspace.commonDir},{remoteURL:()=>f.remote,apiFetch:async()=>new Response(JSON.stringify([pr]),{status:200})});
    const result=await publisher.publish("Lifecycle task","Verified",credential);
    assert.equal(result.branch,branch);
    assert.equal(f.git(f.remote,["rev-parse",`refs/heads/${branch}`]),sha);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("a PR repair publishes its reversal even when the final tree equals the original baseline",async()=>{
  const f=await fixture();
  try {
    const delivered=f.git(f.workspace.path,["rev-parse","HEAD"]);
    f.git(f.workspace.path,["push","origin",`HEAD:refs/heads/${f.workspace.branch}`]);
    await rm(join(f.workspace.path,"change.txt"));
    const context={workspace:f.workspace.path,repository:"acme/app",baseBranch:"main",branch:f.workspace.branch,baseline:f.workspace.baseline,gitDir:f.workspace.gitDir,commonDir:f.workspace.commonDir,previousHead:delivered};
    const publisher=new Publisher(context,{remoteURL:()=>f.remote,apiFetch:async()=>new Response(JSON.stringify([pullRequest(f.git(f.workspace.path,["rev-parse","HEAD"]))]),{status:200})});
    await publisher.commit("REVERT",credential);
    assert.equal((await publisher.status()).changed,true);
    const result=await publisher.publish("Revert addition","Requested changes",credential);
    assert.notEqual(result.commit,delivered);
    assert.equal(f.git(f.remote,["rev-parse",`refs/heads/${f.workspace.branch}`]),result.commit);
    assert.equal(f.git(f.workspace.path,["diff",f.workspace.baseline,"HEAD"]),"");
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("a repair cannot recreate a closed pull request",async()=>{
  const f=await fixture();
  try {
    const previousHead=f.git(f.workspace.path,["rev-parse","HEAD"]);
    f.git(f.workspace.path,["push","origin",`HEAD:refs/heads/${f.workspace.branch}`]);
    await writeFile(join(f.workspace.path,"repair.txt"),"repair");
    const methods:string[]=[];
    const publisher=new Publisher({workspace:f.workspace.path,repository:"acme/app",baseBranch:"main",branch:f.workspace.branch,baseline:f.workspace.baseline,gitDir:f.workspace.gitDir,commonDir:f.workspace.commonDir,previousHead,previousPullRequest:"https://github.com/acme/app/pull/17"},{remoteURL:()=>f.remote,apiFetch:async(url,init)=>{methods.push(init?.method??"GET");assert.equal(String(url),"https://api.github.com/repos/acme/app/pulls/17");return new Response(JSON.stringify({...pullRequest(previousHead),state:"closed"}),{status:200});}});
    await publisher.commit("REPAIR",credential);
    await assert.rejects(publisher.publish("Repair","Requested changes",credential),/changed|closed|match/i);
    assert.ok(!methods.includes("POST"));
    assert.equal(f.git(f.remote,["rev-parse",`refs/heads/${f.workspace.branch}`]),previousHead);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("trusted connector commits uncommitted task files without agent access to shared Git metadata",async()=>{
  const f=await fixture(false);
  try {
    const publisher=new Publisher({workspace:f.workspace.path,repository:"acme/app",baseBranch:"main",branch:f.workspace.branch,baseline:f.workspace.baseline,gitDir:f.workspace.gitDir,commonDir:f.workspace.commonDir});
    assert.deepEqual(await publisher.changedFiles(),["change.txt"]);
    await assert.rejects(publisher.status(),/Uncommitted changes/);
    const result=await publisher.commit("JUA-28",credential);
    assert.equal(result.changed,true);
    assert.equal(result.commit,f.git(f.workspace.path,["rev-parse","HEAD"]));
    assert.equal(f.git(f.workspace.path,["show","-s","--format=%an <%ae>","HEAD"]),`${credential.author_name} <${credential.author_email}>`);
    assert.equal(f.git(f.workspace.path,["show","-s","--format=%s","HEAD"]),"chore: deliver JUA-28");
    assert.equal(f.git(f.workspace.path,["status","--porcelain"]),"");
    assert.equal((await publisher.status()).changed,true);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("every trusted ref update disables repository hooks",async()=>{
  const f=await fixture(false);
  try {
    const calls:string[][]=[];
    const runCommand:typeof command=async(binary,args,options={})=>{
      calls.push(args);
      return command(binary,args,options);
    };
    const publisher=new Publisher({workspace:f.workspace.path,repository:"acme/app",baseBranch:"main",branch:f.workspace.branch,baseline:f.workspace.baseline,gitDir:f.workspace.gitDir,commonDir:f.workspace.commonDir},{runCommand});
    await publisher.commit("JUA-SECURITY",credential);
    const refUpdate=calls.find(args=>args.includes("update-ref"));
    assert.ok(refUpdate);
    assert.deepEqual(refUpdate!.slice(0,3),["--git-dir",f.workspace.commonDir,"-c"]);
    assert.ok(refUpdate!.includes("core.hooksPath=/dev/null"));
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("pushes with a temporary app credential and creates a verified PR without gh",async()=>{
  const f=await fixture();
  try {
    const sha=f.git(f.workspace.path,["rev-parse","HEAD"]);
    const commandCalls:{args:string[];env?:NodeJS.ProcessEnv}[]=[];
    const runCommand:typeof command=async(binary,args,options={})=>{
      assert.equal(binary,"git");
      commandCalls.push({args,env:options.env});
      return command(binary,args,options);
    };
    const apiCalls:{url:string;init:RequestInit}[]=[];
    const apiFetch:typeof fetch=async(input,init={})=>{
      apiCalls.push({url:String(input),init});
      if(init.method==="POST")return new Response(JSON.stringify(pullRequest(sha)),{status:201,headers:{"content-type":"application/json"}});
      return new Response("[]",{status:200,headers:{"content-type":"application/json"}});
    };
    const publisher=new Publisher({workspace:f.workspace.path,repository:"acme/app",baseBranch:"main",branch:f.workspace.branch,baseline:f.workspace.baseline,gitDir:f.workspace.gitDir,commonDir:f.workspace.commonDir},{runCommand,apiFetch,remoteURL:()=>f.remote});
    const result=await publisher.publish("Task result","Summary",credential);

    assert.equal(result.pr_url,"https://github.com/acme/app/pull/17");
    assert.equal(result.commit,sha);
    assert.equal(f.git(f.remote,["rev-parse",`refs/heads/${f.workspace.branch}`]),sha);
    assert.equal(apiCalls.length,2);
    assert.equal(apiCalls[0].url.startsWith("https://api.github.com/repos/acme/app/pulls?"),true);
    assert.equal((apiCalls[0].init.headers as Record<string,string>).authorization,`Bearer ${credential.token}`);
    assert.deepEqual(JSON.parse(String(apiCalls[1].init.body)),{title:"Task result",head:`acme:${f.workspace.branch}`,base:"main",body:"Summary",draft:false});
    assert.equal(commandCalls.some(call=>call.args.includes("gh")),false);
    assert.equal(commandCalls.every(call=>!call.args.join(" ").includes(credential.token)),true);
    const askpass=commandCalls.find(call=>call.args.includes("push"))?.env?.GIT_ASKPASS;
    assert.ok(askpass);
    await assert.rejects(access(askpass!));
    assert.equal(f.git(f.workspace.path,["config","remote.origin.url"]),f.remote);
  } finally {await rm(f.root,{recursive:true,force:true});}
});

test("reuses a matching open PR and rejects a PR for a different commit",async()=>{
  const f=await fixture();
  try {
    const sha=f.git(f.workspace.path,["rev-parse","HEAD"]);
    let posts=0;
    const apiFetch:typeof fetch=async(_input,init={})=>{
      if(init.method==="POST"){posts++;return new Response("{}",{status:201,headers:{"content-type":"application/json"}});}
      return new Response(JSON.stringify([pullRequest(sha)]),{status:200,headers:{"content-type":"application/json"}});
    };
    const publisher=new Publisher({workspace:f.workspace.path,repository:"acme/app",baseBranch:"main",branch:f.workspace.branch,baseline:f.workspace.baseline,gitDir:f.workspace.gitDir,commonDir:f.workspace.commonDir},{apiFetch,remoteURL:()=>f.remote});
    await publisher.publish("Task result","Summary",credential);
    assert.equal(posts,0);
  } finally {await rm(f.root,{recursive:true,force:true});}

  const other=await fixture();
  try {
    const publisher=new Publisher({workspace:other.workspace.path,repository:"acme/app",baseBranch:"main",branch:other.workspace.branch,baseline:other.workspace.baseline,gitDir:other.workspace.gitDir,commonDir:other.workspace.commonDir},{
      apiFetch:async(_input,init={})=>init.method==="POST"
        ? new Response(JSON.stringify(pullRequest("0".repeat(40))),{status:201,headers:{"content-type":"application/json"}})
        : new Response("[]",{status:200,headers:{"content-type":"application/json"}}),
      remoteURL:()=>other.remote
    });
    await assert.rejects(publisher.publish("Task result","Summary",credential),/does not match/);
  } finally {await rm(other.root,{recursive:true,force:true});}
});
