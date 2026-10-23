import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { AppServerSession } from "../../src/app-server/session.ts";

function child(outcome: "completed" | "blocked" = "completed") {
  return spawn(process.execPath, ["--input-type=module", "-e", `
    import readline from 'node:readline';
    const rl=readline.createInterface({input:process.stdin});
    let turn=0;
    rl.on('line',line=>{
      const message=JSON.parse(line);
      if(message.id===undefined)return;
      let result={};
      if(message.method==='initialize')result={ready:true};
      if(message.method==='permissionProfile/list')result={data:[{id:'dev-orchestrator'}],nextCursor:null};
      if(message.method==='account/read')result={account:{type:'chatgpt'}};
      if(message.method==='thread/start') {
        if(message.params.model && message.params.model!=='gpt-6-luna')process.exit(9);
        result={thread:{id:'thread-session-test'}};
      }
      if(message.method==='thread/resume')result={thread:{id:message.params.threadId}};
      if(message.method==='command/exec') {
        if(message.params.sandboxPolicy || message.params.permissionProfile!=='dev-orchestrator' || message.params.timeoutMs>120000)process.exit(13);
        result={exitCode:message.params.command[0]==='false'?1:0,stdout:'bounded output',stderr:''};
      }
      process.stdout.write(JSON.stringify({id:message.id,result})+'\\n');
      if(message.method==='turn/start') {
        if(message.params.effort && message.params.effort!=='low')process.exit(10);
        if(message.params.threadId!=='thread-session-test')process.exit(8);
        turn++;
        process.stdout.write(JSON.stringify({method:'item/agentMessage/delta',params:{threadId:'thread-session-test',turnId:'turn-'+turn,itemId:'item-'+turn,delta:'Working on the task.'}})+'\\n');
        process.stdout.write(JSON.stringify({method:'item/completed',params:{threadId:'thread-session-test',turnId:'turn-'+turn,item:{type:'agentMessage',text:JSON.stringify({outcome:${JSON.stringify(outcome)}})}}})+'\\n');
        process.stdout.write(JSON.stringify({method:'turn/completed',params:{threadId:'thread-session-test',turn:{status:'completed'}}})+'\\n');
      }
    });
  `], { stdio: ["pipe", "pipe", "pipe"], detached: true });
}

test("session initializes once, discovers profiles, starts and resumes a persistent thread across turns", async () => {
  const session = new AppServerSession(child());
  const events: unknown[] = [];
  session.on("event", event => events.push(event));
  try {
    await session.initialize();
    assert.equal(await session.authenticated(), true);
    const threadId = await session.startThread({ cwd: "/tmp/task", permissions: "dev-orchestrator", model: "gpt-6-luna" });
    assert.equal(threadId, "thread-session-test");
    assert.equal((await session.runTurn("First turn", { effort: "low" })).status, "completed");
    assert.equal(await session.resumeThread(threadId, { cwd: "/tmp/task", permissions: "dev-orchestrator" }), threadId);
    assert.equal((await session.runTurn("Second turn")).status, "completed");
    assert.equal(events.filter((event: any) => event.kind === "message_delta").length, 2);
  } finally { session.close(); }
});

test("environment commands use the configured sandbox without a model turn and retain nonzero status", async () => {
  const session = new AppServerSession(child());
  try {
    await session.initialize();
    assert.deepEqual(await session.exec(["false"], "/tmp/task", new AbortController().signal), { exitCode: 1, stdout: "bounded output", stderr: "" });
  } finally { session.close(); }
});

test("a structured blocked outcome is returned to the caller for terminal handling", async () => {
  const session = new AppServerSession(child("blocked"));
  try {
    await session.initialize();
    await session.startThread({ cwd: "/tmp/task", permissions: "dev-orchestrator" });
    assert.deepEqual(await session.runTurn("Do the work"), { status: "completed", outcome: "blocked" });
  } finally { session.close(); }
});

test("only completed turns with a completed structured outcome are successful", async () => {
  const session = new AppServerSession(child());
  try {
    await session.initialize();
    await session.startThread({ cwd: "/tmp/task", permissions: "dev-orchestrator" });
    assert.equal((await session.runTurn("Do the work")).status, "completed");
  } finally { session.close(); }
});
