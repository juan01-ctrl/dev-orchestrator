# Bounded Task Recovery Implementation Plan

**Goal:** Automatically prepare and validate task workspaces, preserve useful results, and recover the failing phase within persistent limits.

**Architecture:** Reuse the app-server sandbox, existing run event protocol, snapshot and local journal. Detect setup/validation commands from repository metadata; execute them without inference only when changed files need them. Keep publication and verification checkpoints so a provider outage never restarts implementation.

**Execution:** Inline implementation, authorized by the user's request. Preserve unrelated package edits. No remote push, deployment, package publication or real-provider smoke task.

## Constraints and decisions

- No new service, runtime dependency or general workflow framework.
- Default Node support uses the existing package manager/lockfile; other stacks can provide explicit argv commands in optional `.dev-orchestrator.json` (`setup`, `validate`).
- Text/documentation-only changes skip framework installation/checks by default; explicit configured checks override this.
- Run repository commands only through `command/exec` in the app-server sandbox. Enable its network proxy with the immutable server-approved exact hosts; never enable unrestricted networking or pass GitHub credentials to repository commands.
- Results contain bounded summary/checks/blocker details; legacy outcome-only connectors remain readable.
- At most three execution/repair attempts and a twenty-minute lifecycle budget, preserved across reconnects. Only real missing-context questions use clarification.
- Retain publish/verify checkpoints. Temporary GitHub verification errors retry verification, not coding.

## Work units

1. **Structured outcomes and sandbox commands.** Add result normalization/redaction and structured app-server responses. Add an explicit sandbox command method with bounded timeout/output and exact-host network configuration. Tests: result categories, invalid context claims, sandbox command failures and protocol compatibility.
2. **Lazy environment preparation and bounded repair.** Add repository metadata detection plus configured argv commands; lazy setup keyed by manifest/lock fingerprint; skip text-only tasks. Worker runs deterministic validation, returns failures to the same thread up to three times, and persists deadline/outcome/publication checkpoints. Tests: missing dependencies, one repaired check, exhausted checks, cached setup, no-install text task, resume after publication.
3. **Server reporting and lifecycle budgets.** Preserve sanitized summaries/checks and actual blockers in event/results/Slack/PR. Persist claim deadlines, bound total failures, retain retryable PR verification as running, and expire exhausted tasks with an outbox report. Tests: report payloads, temporary verification outage, lifecycle deadline, total failures and contextual blockers.
4. **Integration, release instructions and review.** Update activity labels and protocol docs, run connector typecheck/tests, platform tests/formatter where available, and inspect the complete diff. Prepare explicit commands to commit/push/merge to main without staging unrelated local package edits. Any new connector behavior requires a newly published package; do not claim that deploying the server updates an already-running executor.

## Review focus

- Repository scripts, symlinks and configured paths must not escape the task sandbox.
- A failed validation cannot be published as completed.
- A lost acknowledgement must preserve the same publication candidate and event sequence.
- A timeout/restart must not reset the lifecycle budget or make a fresh coding conversation.
- Compatibility with older connectors must preserve honest reporting and fencing.

## Verification record

- Connector: `npm run check` and `npm test` passed (86 tests).
- Server offline checks: `mise exec -- elixir test/offline.exs` passed (43 tests).
- Changed server modules compiled with existing dependency beam paths; changed Elixir sources passed direct Elixir/Phoenix formatter checks. `git diff --check` passed.
- Full `mix test` remains blocked before ExUnit: Mix.PubSub cannot open its internal TCP socket (`:eperm`). Added database-backed lifecycle/report tests still need the normal PostgreSQL test run.
- Installed Codex 0.163.0 experimental JSON schema confirms `command/exec.permissionProfile`; the real app-server smoke probe was blocked by the enclosing environment's `chatgpt.com` network restriction. No real provider task, deployment or package publication was performed.
- Independent read-only review found mixed-stack failed-check loss, HTTP 5xx misclassification and publication prerequisite recovery gaps; each was fixed with regression tests. A final publication-attempt entry guard prevents a fourth attempt after a crash.
- GitHub fetch was blocked by the environment's HTTP proxy (403); remote main freshness/mergeability is not claimed. Unrelated existing package manifest/lock edits remain excluded.
