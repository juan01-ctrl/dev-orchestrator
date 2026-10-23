import test from "node:test";
import assert from "node:assert/strict";
import { CodexSession, CodexBlockedError } from "../src/codex.ts";
import { spawn } from "node:child_process";

function child(mode="ok") {
  return spawn(process.execPath,["--input-type=module","-e",`
    import readline from 'node:readline';
    const rl=readline.createInterface({input:process.stdin});
    rl.on('line',line=>{
      const m=JSON.parse(line); if(!('id' in m))return;
      let result={};
      if(m.method==='account/read')result={account:{type:'chatgpt'}};
      if(m.method==='thread/start') {
        if(${JSON.stringify(mode)}==='resume')process.exit(11);
        if(m.params.permissions!=='dev-orchestrator'||m.params.approvalPolicy!=='never')process.exit(8);
        result={thread:{id:'thread-test'}};
      }
      if(m.method==='thread/resume') {
        if(m.params.threadId!=='thread-test')process.exit(12);
        result={thread:{id:m.params.threadId}};
      }
      process.stdout.write(JSON.stringify({id:m.id,result})+'\\n');
      if(m.method==='turn/start') {
        if(${JSON.stringify(mode)}==='malformed')process.stdout.write('not-json\\n');
        else if(${JSON.stringify(mode)}==='null')process.stdout.write('null\\n');
        else if(${JSON.stringify(mode)}==='commands')for(let i=0;i<3;i++)process.stdout.write(JSON.stringify({method:'item/completed',params:{threadId:'thread-test',item:{type:'commandExecution',command:'git push',exitCode:2,aggregatedOutput:'authentication failed'}}})+'\\n');
        else if(${JSON.stringify(mode)}==='exit')process.exit(3);
        else {
          if(${JSON.stringify(mode)}==='search')for(let i=0;i<4;i++)process.stdout.write(JSON.stringify({method:'item/completed',params:{threadId:'thread-test',item:{type:'commandExecution',command:"/bin/zsh -lc 'rg missing src'",exitCode:1,aggregatedOutput:''}}})+'\\n');
          if(${JSON.stringify(mode)}!=='no_final')process.stdout.write(JSON.stringify({method:'item/completed',params:{threadId:'thread-test',item:{type:'agentMessage',text:JSON.stringify({outcome:${JSON.stringify(mode)}==='model_blocked'?'blocked':'completed'})}}})+'\\n');
          process.stdout.write(JSON.stringify({method:'turn/completed',params:{threadId:'thread-test',turn:{status:${JSON.stringify(mode)}==='failed'?'failed':'completed'}}})+'\\n');
        }
      }
    });
  `],{stdio:["pipe","pipe","pipe"],detached:true});
}

test("real stdio handshake completes a turn without uploading authentication material", async () => {
  const session=new CodexSession(child());
  try {
    await session.initialize(); assert.equal(await session.authenticated(),true);
    await session.run("/tmp/task-checkout","Create a text file",undefined);
  } finally {session.stop();}
});
test("recovery resumes the existing Codex thread instead of starting a duplicate thread",async()=>{
  const session=new CodexSession(child("resume"));
  let persistedThread="";
  try {
    await session.initialize();
    await session.run("/tmp/task-checkout","Continue the interrupted task",undefined,undefined,undefined,undefined,undefined,{
      threadId:"thread-test",
      onThreadStarted:async id=>{persistedThread=id;}
    });
    assert.equal(persistedThread,"thread-test");
  } finally {session.stop();}
});
test("expected search misses inside the usual shell wrapper do not exhaust the budget",async()=>{
  const session=new CodexSession(child("search"));
  try {await session.initialize();await session.run("/tmp/task-checkout","Inspect the project",undefined);}
  finally {session.stop();}
});
for(const mode of ["failed","malformed","null","exit","commands","no_final","model_blocked"]) {
  test(`Codex ${mode} never becomes a successful task`,{timeout:2_000},async()=>{
    const session=new CodexSession(child(mode));
    try {await session.initialize();await assert.rejects(session.run("/tmp/task-checkout","Task",undefined));}
    finally {session.stop();}
  });
}
test("a structured blocked turn reaches the worker as a typed terminal blocker",async()=>{
  const session=new CodexSession(child("model_blocked"));
  try {await session.initialize();await assert.rejects(session.run("/tmp/task-checkout","Task"),error=>error instanceof CodexBlockedError && error.result.blocker?.category === "execution_failed");}
  finally {session.stop();}
});
