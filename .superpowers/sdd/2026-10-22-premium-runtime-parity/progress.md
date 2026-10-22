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

- Status: implementation in progress.
- Added a generic signed endpoint and durable inbox migration; asynchronous Linear lookup is moved out of the request transaction.
- Offline protocol suite currently passes 28 tests, including minimal event normalization and replay payload rejection.

## Task 0 completion (retained)

Task 0: complete (commits e05569f..eb8ce89, tests: bash -lc 'cd connector && npm run check && npm test && cd ../platform && mise exec -- elixir -pa /Users/juanierace/Documents/Projects/dev-orchestrator/platform/_build/test/lib/jason/ebin -pa /Users/juanierace/Documents/Projects/dev-orchestrator/platform/_build/test/lib/req/ebin test/offline.exs' → 26 tests, 0 failures)
