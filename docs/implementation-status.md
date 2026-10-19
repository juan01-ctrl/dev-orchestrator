# Implementation checkpoint — October 19, 2026

The product has a separate source implementation and local Git repository.
It is **not yet an integrated, verified deployment** and has not been pushed.
The existing Symphony installation and its configuration/remote were not changed.

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

Offline compiler warnings identify unavailable Ecto SQL/Postgrex/password/email
packages; compilation against cached libraries is not a substitute for the complete
dependency build. The platform lockfile remains unresolved. The connector lockfile
was generated from the local package cache without global software installation.

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
2. Resolve and commit `platform/mix.lock`; run complete server/connector checks.
3. Complete browser, restart/concurrency and designated provider smoke tests from
   `docs/evaluation.md`, fixing observed failures before claiming completion.
4. Verify access/history of `juan01-ctrl/dev-orchestrator`, then push without force
   and compare local/remote HEAD. A 404 alone does not establish that the repo is absent.
