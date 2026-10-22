# SDD ledger — plan: docs/superpowers/plans/2026-10-22-premium-runtime-parity.md

## Pre-flight

- Task 1 → Task 4: app-server client produces `PublicExecutionEvent`; event mapper consumes it. Compatible by design; wire event type will be frozen in Task 1 tests.
- Task 1 → Task 6: app-server session produces persisted thread IDs and requests; pool/recovery consumes both. Compatible by design; session identity is stored per journal slot.
- Task 2 → Task 3: Linear inbox processor produces normalized issue snapshots; lifecycle/reconciler consumes them. Compatible by design; lifecycle keys distinguish activation generations.
- Task 3 → Task 6: lifecycle cancellation and rework target runs/leases; pool cancellation consumes run state. Compatible by design; cancellation remains fenced server-side.
- Task 4 → Task 6: run PubSub/event schema carries clarification state; Task 6 consumes it for resume. Compatible by design; clarification is typed, not raw app-server payload.
- Task 5 → Task 1/6: immutable policy is passed into app-server and slot pool. Compatible by design; server owns policy, connector validates capabilities.
- Task 7 → Task 2/3: supervised background workers process inbox and outbox records. Compatible by design; bounded concurrency and separate queues prevent starvation.
- Ruling: the native Codex worktree tool attached to the unrelated `symphony-orquestrator` checkout. It was archived immediately; this plan uses a local Git worktree under the correct `dev-orchestrator` repository.

## Task 0

- The 40 pre-existing modified/untracked paths were reviewed as managed repository bootstrap/GitHub App publisher, Slack channel selection/reporting, and activity stream work. No credentials or secret files were included.
- RED: offline suite failed 8/26 because `connections/github.ex` was not loaded.
- GREEN: offline harness now loads GitHub and available Jason/Req ebin paths; 26/26 pass.
- Connector: typecheck passed and tests passed 27/27.
- Full Mix suite remains blocked before ExUnit: Mix 1.19.5 cannot open Mix.PubSub TCP socket (`:eperm`).
- Ruling: retain the offline harness as a limited protocol/provider check; record the socket restriction and do not treat offline success as full server verification.
- Baseline commits: `e11b809` (plan/spec), `c0898f0` (existing managed executor bootstrap), `eb8ce89` (ignore local worktrees).

## Task 1

- Completed in commit `be84af3` (`feat(connector): support persistent app server sessions`).
- App-server tests cover JSON-RPC responses, notifications, server requests, safe events, profile discovery, thread start/resume, multi-turn execution, and completion validation.
- `cd connector && npm run check && npm test` → typecheck passed; 36 tests, 0 failures.

## Task 2

- Completed in commit `e2924c9` (`feat(linear): add durable generic webhook intake`).
- Generic webhook verifies and stores minimal normalized event data; GraphQL and project dispatch happen asynchronously, with duplicate delivery protection and bounded retry backoff.
- Legacy per-connection route remains available with a deprecation warning.
- Offline protocol suite: 28 tests, 0 failures at Task 2 boundary.

## Task 3

- Completed in commit `e695549` (`feat(linear): reconcile issue lifecycles`).
- Added per-project issue activation state, terminal-state cancellation, rework activations, and a paginated per-connection `updatedAt` reconciler with resumable cursors.
- Lifecycle unit tests cover team/project/state eligibility; full database transition tests still require the full Mix/PostgreSQL test environment.

## Task 4

- Completed in commit `a7d0359` (`feat(runs): stream live execution activity`).
- Connector batches safe agent-message deltas, sends sanitized activity events, and serializes them with progress writes.
- Server validates/redacts activity events, broadcasts only after commit, and the run LiveView subscribes to authorized run updates instead of polling every five seconds.
- Task-boundary verification: connector checks/tests passed; offline platform suite passed 31 tests, 0 failures.

## Task 5

- Status: implementation in progress.
- Added deployment-owned model catalog, automatic Luna/low vs. Sol/high classification, validated project override, and immutable policy snapshot at lease time.
- Connector applies the selected model/effort, removes broad credential-path access, and brokers exact-host network amendments and workspace-only permission requests fail-closed.
- Connector checks/tests: 40 passed; offline platform suite: 34 passed.
- Network egress is not enabled globally. Only explicit exact-host app-server amendments from the deployment allowlist can be applied; real dependency-install smoke test remains outstanding.

## Task 6

- Partial: bounded local execution slots (`DEV_ORCHESTRATOR_SLOTS`, 1–10), independent journal directories per slot, shared repository cache, and shared cancellation are implemented in commit `0c3c73d` (`feat(executors): add parallel local execution slots`).
- Added same-thread recovery: the connector journals the Codex thread ID, workspace, and baseline; the server renews only a live, generation-fenced lease; restart resumes the existing app-server thread and retained worktree instead of claiming/re-running a new task. Resume events avoid replaying the initial task lifecycle.
- Added race-guarded lock recovery with PID liveness checks, legacy PID-lock compatibility, lock-file safety checks, and ownership-aware release. Active, malformed, and unsafe locks fail closed; stale locks can recover automatically.
- Connector verification after recovery/lock changes: `npm run check` passed; `npm test` passed 47/47. Offline platform harness passed 36/36. Full `mise exec -- mix test` remains blocked before ExUnit because Mix.PubSub cannot open a local TCP socket (`:eperm`).
- Still outstanding: interactive durable clarification and response delivery; full DB-backed server verification and crash-boundary/duplicate-publication scenarios.

## Task 7

- Partial: final report delivery now drains concurrently with bounded workers; known provider rejections receive durable 5s/30s/120s/600s backoff and then dead-letter. Unknown send outcomes remain `ambiguous` and are not resent automatically.
- Added migration `20261024000000_harden_outbox_retries.exs` and updated deployment/protocol/security/evaluation docs for model/network policy and connector slot capacity.
- Offline platform suite: 36 tests, 0 failures. Full delivery/PostgreSQL integration tests are still blocked by the local Mix socket restriction.
