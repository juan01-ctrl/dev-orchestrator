import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { AppServerClient } from "../../src/app-server/client.ts";
import { AppServerSession } from "../../src/app-server/session.ts";

function child() {
  return spawn(process.execPath, ["--input-type=module", "-e", `
    import readline from 'node:readline';
    const rl=readline.createInterface({input:process.stdin});
    rl.on('line',line=>{
      const message=JSON.parse(line);
      if(message.id!==undefined && message.method==='initialize') {
        process.stdout.write(JSON.stringify({id:message.id,result:{ready:true}})+'\\n');
        process.stdout.write(JSON.stringify({method:'turn/started',params:{threadId:'thread-client-test'}})+'\\n');
        process.stdout.write(JSON.stringify({id:'server-request-1',method:'item/fileChange/requestApproval',params:{threadId:'thread-client-test'}})+'\\n');
      } else if(message.id==='server-request-1') {
        process.stdout.write(JSON.stringify({method:'serverRequest/resolved',params:{}})+'\\n');
      }
    });
  `], { stdio: ["pipe", "pipe", "pipe"], detached: true });
}

test("JSON-RPC client handles responses, notifications, and server requests independently", async () => {
  const client = new AppServerClient(child());
  const notification = new Promise<any>(resolve => client.once("notification", resolve));
  const serverRequest = new Promise<void>((resolve, reject) => {
    client.once("serverRequest", async request => {
      try {
        assert.equal(request.method, "item/fileChange/requestApproval");
        await client.respond(request.id, { decision: "accept" });
        resolve();
      } catch (error) { reject(error); }
    });
  });

  try {
    assert.deepEqual(await client.request("initialize", {}), { ready: true });
    assert.equal((await notification).method, "turn/started");
    await serverRequest;
  } finally { client.close(); }
});

test("JSON-RPC server errors reject only their matching request", async () => {
  const process = spawn(globalThis.process.execPath, ["--input-type=module", "-e", `
    import readline from 'node:readline';
    readline.createInterface({input:process.stdin}).on('line',line=>{
      const message=JSON.parse(line);
      process.stdout.write(JSON.stringify({id:message.id,error:{code:-32601,message:'not found'}})+'\\n');
    });
  `], { stdio: ["pipe", "pipe", "pipe"], detached: true });
  const client = new AppServerClient(process);
  try {
    await assert.rejects(client.request("unknown/method", {}), /Codex rejected the configured request/);
    assert.equal(client.isClosed(), false);
  } finally { client.close(); }
});

test("missing Codex binary reports the executable, error code, and possible missing working directory", async () => {
  const session = AppServerSession.open({ binary: "missing-codex-test-binary", cwd: process.cwd() });
  try {
    await assert.rejects(session.initialize(), /missing-codex-test-binary.*ENOENT.*working directory/);
  } finally { session.close(); }
});
