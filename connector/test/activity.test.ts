import test from "node:test";
import assert from "node:assert/strict";
import { activityForNotification } from "../src/activity.ts";

test("Codex notifications become safe, useful progress stages",()=>{
  assert.deepEqual(activityForNotification({method:"turn/started",params:{threadId:"thread-1"}}),"agent_started");
  assert.deepEqual(activityForNotification({method:"item/started",params:{item:{type:"fileChange",changes:[{path:"private.txt"}]}}}),"editing");
  assert.deepEqual(activityForNotification({method:"item/started",params:{item:{type:"commandExecution",command:"npm test"}}}),"validating");
  assert.equal(activityForNotification({method:"item/completed",params:{item:{type:"commandExecution",command:"npm test",exitCode:0,status:"completed",aggregatedOutput:"private output"}}}),undefined);
  assert.equal(activityForNotification({method:"item/completed",params:{item:{type:"commandExecution",command:"echo test",exitCode:0,status:"completed"}}}),undefined);
});

test("Codex prose and command output never become activity messages",()=>{
  assert.equal(activityForNotification({method:"item/agentMessage/delta",params:{delta:"secret reasoning"}}),undefined);
  assert.equal(activityForNotification({method:"item/started",params:{item:{type:"commandExecution",command:"cat credentials.json"}}}),"working");
});
