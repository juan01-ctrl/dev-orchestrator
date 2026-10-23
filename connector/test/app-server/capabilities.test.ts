import test from "node:test";
import assert from "node:assert/strict";
import { authorizeCommand, authorizeFileChange } from "../../src/app-server/capabilities.ts";

test("commands stay inside the project workspace and cannot expand filesystem access", () => {
  const workspace = "/tmp/task-workspace";
  assert.equal(authorizeCommand(workspace, [], { cwd: workspace, command: "npm test" }), true);
  assert.equal(authorizeCommand(workspace, [], { cwd: "/tmp/other-repo", command: "git status" }), false);
  assert.equal(authorizeCommand(workspace, [], { cwd: workspace, additionalPermissions: { filesystem: "write" } }), false);
  assert.equal(authorizeFileChange(workspace, { grantRoot: workspace + "/.agents/skills" }), true);
  assert.equal(authorizeFileChange(workspace, { grantRoot: workspace + "/.git/config" }), false);
  assert.equal(authorizeFileChange(workspace, { grantRoot: workspace + "/src/../.git/refs/heads/main" }), false);
  assert.equal(authorizeFileChange(workspace, { grantRoot: "/Users/juan/.codex/skills" }), false);
  assert.equal(authorizeFileChange(workspace, {}), false);
});

test("only explicit exact allowlisted network hosts receive an app-server amendment", () => {
  const amendment = { host: "registry.npmjs.org", action: "allow" };
  assert.deepEqual(authorizeCommand("/tmp/task", ["registry.npmjs.org"], { cwd: "/tmp/task", proposedNetworkPolicyAmendments: [amendment] }), {
    applyNetworkPolicyAmendment: { network_policy_amendment: amendment }
  });
  assert.equal(authorizeCommand("/tmp/task", ["registry.npmjs.org"], { proposedNetworkPolicyAmendments: [{ host: "evil.test", action: "allow" }] }), false);
  assert.equal(authorizeCommand("/tmp/task", ["registry.npmjs.org"], { proposedNetworkPolicyAmendments: [{ host: "registry.npmjs.org", action: "deny" }] }), false);
  assert.equal(authorizeCommand("/tmp/task", ["registry.npmjs.org"], { proposedNetworkPolicyAmendments: [{ host: "sub.registry.npmjs.org", action: "allow" }] }), false);
  assert.equal(authorizeCommand("/tmp/task", ["registry.npmjs.org"], { proposedNetworkPolicyAmendments: [{ host: "registry.npmjs.org", action: "allow" }, { host: "hex.pm", action: "allow" }] }), false);
});
