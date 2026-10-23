import test from "node:test";
import assert from "node:assert/strict";
import { command } from "../src/process.ts";

test("classifies a rejected Git checkout without exposing command output", async () => {
  await assert.rejects(
    command("/bin/sh", ["-c", "printf 'remote: Repository not found. ghs_private_marker\\n' >&2; exit 128"]),
    (error: unknown) => error instanceof Error &&
      (error as Error & {reason?:string}).reason === "access_denied" &&
      !error.message.includes("ghs_private_marker")
  );
});

test("classifies a Git transport failure separately from local storage", async () => {
  await assert.rejects(
    command("/bin/sh", ["-c", "printf 'fatal: CONNECT tunnel failed, response 403\\n' >&2; exit 128"]),
    (error: unknown) => error instanceof Error &&
      (error as Error & {reason?:string}).reason === "network"
  );
});

test("classifies a GitHub HTTP 403 as repository access denied", async () => {
  await assert.rejects(
    command("/bin/sh", ["-c", "printf 'fatal: The requested URL returned error: 403\\n' >&2; exit 128"]),
    (error: unknown) => error instanceof Error &&
      (error as Error & {reason?:string}).reason === "access_denied"
  );
});
