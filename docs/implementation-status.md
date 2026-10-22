# Implementation checkpoint — October 19, 2026

## Premium runtime parity — October 22, 2026

This implementation is in the isolated worktree
`/Users/juanierace/Documents/Projects/dev-orchestrator/.worktrees/premium-runtime-parity`
on branch `feat/premium-runtime-parity`. It has not been pushed or deployed.

Implemented locally in reviewable commits:

- Persistent bidirectional Codex app-server sessions and redacted live activity.
- Generic signed Linear webhook inbox, asynchronous issue processing and periodic
  lifecycle reconciliation.
- Immutable server-selected task model/effort policy and workspace-scoped permission
  broker. Routine tasks select `gpt-6-luna`/low; planning, reviews, fixes, security
  and investigation select `gpt-6.1-sol`/high. Project overrides are restricted to
  the deployment-supported catalog.
- Bounded exact-host network amendments only; arbitrary hosts and permission
  expansion are denied. Network egress is not globally enabled.
- Connector slots (1–10 via `DEV_ORCHESTRATOR_SLOTS`) with independent journals and
  task worktrees; shared managed repository cache.
- Concurrent final-report delivery with durable bounded retry for known provider
  rejection and no automatic retry for ambiguous sends.

Current verification:

| Check | Result |
|---|---|
| Connector `npm run check && npm test` | Passed after recovery/clarification changes: 49 tests, 0 failures |
| Platform `mise exec -- mix test` | User-run: 94 tests, 0 failures |
| Platform `mise exec -- mix format --check-formatted` | User-run: passed after formatting `runs.ex` |
| Platform offline harness | Passed: 37 tests, 0 failures; database-backed assertions are not part of this harness |
| Clarification contract tests | Passed directly: 3 tests, 0 failures |
| Changed/new Elixir syntax | Parsed successfully: 20 files |
| `git diff --check` | Passed |
| Full platform `mise exec -- mix test` in this sandbox | Blocked before ExUnit: Mix 1.19.5 cannot open its local PubSub TCP socket (`:eperm`); the user separately ran the full suite successfully |
| Project `mix format --check-formatted` in this sandbox | Blocked by the same Mix socket restriction; the user separately ran the full check successfully |
| Real Linear/Slack/GitHub/Codex smoke tests | Not run; no external task/message, PR, or deployment was initiated |

Same-thread resume, stale-lock recovery, durable Slack/UI clarification, component
readiness diagnostics, and low-cardinality intake/reconciliation/heartbeat/
lease/run-event/report telemetry are implemented in this worktree. Database-backed
run/controller/LiveView verification and full Mix formatting are now confirmed by
the user's successful platform test/format runs. Executor slot-capacity gauges and
the owner-authorized provider end-to-end scenarios remain open. The source is still
not a production-verified release until those remaining gates pass.

## Parity acceptance run — October 22, 2026

- Connector typecheck and suite: **49 passed, 0 failed** (run in the worktree).
- Platform suite: **94 passed, 0 failed** (reported by the user from their local environment).
- Platform formatter check: **passed** (reported by the user after correcting `runs.ex`).
- No real Linear issue, Slack notification, GitHub PR, dependency-install network test,
  concurrent provider task, or connector restart scenario was triggered. These require
  a designated test project/repository/channel and owner authorization; acceptance
  criteria remain incomplete rather than inferred from unit tests.

## Automatic repository bootstrap — October 21, 2026

The connector now bootstraps the selected project repository directly from its
verified GitHub App installation. A local clone, per-project source mapping,
`gh` login, and manual `allow` command are not prerequisites. New pairing writes
connector config version 2; version 1 remains readable while its local mappings
are ignored.

- The server issues lease-bound installation tokens restricted to the exact
  repository: contents read for checkout, and contents plus pull-request write
  for publication. Tokens are not persisted in the connector journal, Git
  remote, event stream, or Codex process environment.
- The connector keeps a private bare cache and one isolated worktree per task
  lifecycle beneath the connector config directory. It uses the GitHub App bot
  identity and opens/verifies the PR through GitHub REST, without `gh`.
- Acknowledged successful worktrees are eligible for cleanup after 24 hours;
  terminal failed/blocked worktrees after 7 days. Unfinished work and the shared
  bare cache are retained. Unsafe or unrecognized worktrees fail closed.
- Dashboard activity includes repository preparation and PR verification, and
  maps checkout/setup failures to bounded, actionable messages.

Verification in this environment: connector suite **27 passed** and
`npm run check` passed. The platform suite could not start: Mix 1.19 fails before
ExUnit because its local PubSub TCP socket is denied (`:eperm`). No real-provider
smoke test, real Codex task, GitHub PR creation, deployment, push, or merge was
performed.
This is implemented source, not a verified production deployment.

The product has a separate source implementation and local Git repository.
It is **not yet an integrated, verified deployment** and has not been pushed.
The existing Symphony installation and its configuration/remote were not changed.

## Parity plan baseline — October 22, 2026

Fresh verification for the premium runtime parity work:

| Check | Result |
|---|---|
| `cd connector && npm run check` | Passed |
| `cd connector && npm test` | 27 passed, 0 failed |
| `cd platform && mise exec -- elixir test/offline.exs` | 26 passed, 0 failed; emits two compile warnings because the database-backed `Connections` module is intentionally outside this offline harness |
| `cd platform && mise exec -- mix test` | Blocked before ExUnit: Mix 1.19.5 cannot open its PubSub TCP socket (`:eperm`) in this environment |

The offline harness now loads the GitHub provider and the already-built Jason/Req
dependencies when available. This corrects the earlier false-negative run where
eight provider tests failed because the harness omitted GitHub; it does not replace
the full Mix/PostgreSQL suite. At this baseline checkpoint, app-server resume,
generic Linear webhooks, issue reconciliation, PubSub streaming, model/capability
policy and executor slot pooling were not yet implemented; subsequent sections
record the work completed after that point.

## Source implemented

- Phoenix/LiveView web application, email/password registration and verification,
  session revocation/reset, organization membership and scoped project rules.
- Provider OAuth state binding, encrypted project connection grants, GitHub App
  installation verification, Slack/Linear adapters and signed Linear issue intake.
- One-use executor enrollment, local repository authorization, durable fenced
  dispatch, three-equivalent-failure budget, reconciliation and report outbox.
- TypeScript connector using the real Codex app-server protocol, isolated checkouts,
  trusted-host Git publication, structured final outcomes and a local recovery journal.
- Container/Compose configuration, CI and evaluation/deployment documentation.

## Evidence from this environment

| Check | Result |
|---|---|
| Connector TypeScript (`npm run check`) | Passed |
| Connector unit/process/Git tests (`npm test`) | 18 passed |
| Pure server checks (`elixir test/offline.exs`) | 13 passed |
| Auth/project empty-state HEEx render checks | 2 passed using existing cached Phoenix dependencies |
| Remaining server source compilation | Passed excluding Repo and Mailer, whose packages are unavailable |
| Local database Compose syntax | `docker compose config --quiet` passed |
| Full `mix deps.get` / `mix test` | Blocked: TCP-lock/Mix.PubSub `:eperm` |
| Live PostgreSQL, browser UI and container startup | Not verified: sockets denied; Docker daemon absent |
| Real Codex inference / GitHub PR / Slack / Linear smoke test | Not run; no real-account tasks or external messages sent |
| Git destination inspection | Terminal CONNECT proxy 403; connected GitHub read 404 (absence vs access cannot be distinguished) |
| Push / remote HEAD verification | Not performed; destination inaccessible and integrated gates incomplete |

Offline compiler warnings identify database-backed modules omitted by the offline
harness; they are not a substitute for the complete dependency build. Both
`connector/package-lock.json` and `platform/mix.lock` are tracked. The connector
lockfile was generated from the local package cache without global software
installation.

## Review findings addressed

Regression tests were observed failing, then passing, for malformed/null Codex
messages, native repeated-command failures, expected search misses under shell
wrappers, missing/blocked final outcomes, credential-like event data and invalid
candidate URLs. Git author lookup also supports existing global identity without
modifying it. OAuth connection initiation is CSRF-protected POST.

Review was performed by the implementer without delegation, as requested. No
independent reviewer or security audit is implied. Database-dependent authorization,
lease races, transaction behavior, actual provider schemas and startup still require
the complete integration gate, not just a static review.

## Decisions and their costs

- Use a separate repository on the requested `main` branch, not a worktree of the
  old project. Relocation, if needed, affects only these new files.
- Manually assemble standard Phoenix modules because the generator/dependency
  setup is unavailable. This needs extra authentication/startup review once the
  dependencies can be installed; it is not advertised as generator-verified auth.
- Continue independent offline module work while database/UI gates are blocked.
  Source coverage does not establish tenant isolation or concurrency at runtime.
- Use one execution slot per connector in the first evaluation. Parallel work
  requires multiple enrolled executors; per-host parallel slots need a later journal design.
- Support a narrowly scoped GitHub installation (up to 100 listed entries) initially.
  Larger installations fail closed rather than skipping repository authorization.

## Resume

1. Start Docker outside the restricted execution environment and follow the README.
2. Verify the tracked `platform/mix.lock`; run complete server/connector checks.
3. Complete browser, restart/concurrency and designated provider smoke tests from
   `docs/evaluation.md`, fixing observed failures before claiming completion.
4. Verify access/history of `juan01-ctrl/dev-orchestrator`, then push without force
   and compare local/remote HEAD. A 404 alone does not establish that the repo is absent.
