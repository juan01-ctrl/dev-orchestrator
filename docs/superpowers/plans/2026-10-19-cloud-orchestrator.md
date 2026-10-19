# Cloud Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Work in this session with one agent unless the user requests delegation.

**Goal:** Build and verify a separate multi-tenant cloud platform with real local Codex execution, then push it to `juan01-ctrl/dev-orchestrator`.

**Architecture:** Phoenix/LiveView and PostgreSQL own authentication, tenant-scoped projects, connections and durable dispatch. A Node.js/TypeScript connector uses outbound HTTPS and a private local Codex app-server process. Reuse the behavior of the existing Symphony runner through explicit adapters, not its singleton config or running process.

**Tech Stack:** Elixir/Phoenix/LiveView/Ecto/PostgreSQL, Node.js/TypeScript, official Codex app-server JSON-RPC, GitHub App, Slack/Linear OAuth, Docker. Resolve supported exact dependency versions from current official docs during setup and commit lockfiles.

**Spec:** `docs/superpowers/specs/2026-10-19-cloud-orchestrator-design.md`.

## Global Constraints

- Work only in `/Users/juanierace/Documents/Projects/dev-orchestrator`.
- Do not edit the existing Symphony installation, source checkout, WORKFLOW.md, model configuration, credential stores, environment or port 4000.
- Use port 4100, a separate PostgreSQL database and connector-owned runtime directory.
- Use real existing local Codex authentication without uploading provider credentials.
- No actual deployment, provider-app registration, forced push, automatic merge or production operations.
- Do not present test providers as connected production integrations.
- Preserve all user changes. Use Conventional Commits without authorship trailers.
- Publish completed verified work to `https://github.com/juan01-ctrl/dev-orchestrator.git`; do not change the previous project's origin.

## Review Focus

1. Guessed cross-tenant IDs and forged event payloads must not read or mutate another tenant's task (Tasks 1 and 4).
2. Same-origin OAuth replay, login-session swapping and missing provider configuration must fail without fake connected state (Task 2).
3. Reconnect after lease expiry or lost final-result acknowledgement must not create duplicate PRs or silently reassign active work (Tasks 4 and 6).
4. Symlink escapes and agent-controlled Git hooks/config must not execute with customer host credentials (Tasks 3 and 5).
5. GitHub success followed by Slack timeout must preserve successful task state and avoid repeated development work (Task 6).

## File and Interface Map

| Owner | Principal files | Contract |
|---|---|---|
| Identity | `platform/lib/dev_orchestrator/accounts.ex`, `accounts/scope.ex`, `accounts/user.ex`, `organizations.ex` | `Scope` contains authenticated user and validated organization membership |
| Projects | `platform/lib/dev_orchestrator/projects.ex`, `projects/project.ex` | `get_project(scope, id)`, `create_project(scope, attrs)`, immutable `snapshot(project)` |
| Connections | `platform/lib/dev_orchestrator/connections.ex`, `connections/{oauth,secret_box,github,linear,slack}.ex` | Provider grants resolve only under authorized organization/project |
| Executors | `platform/lib/dev_orchestrator/executors.ex`, `executors/{enrollment,executor,binding}.ex` | `enroll(code, attrs)`, `authenticate(token)`, `bind(scope, executor_id, project_id)` |
| Dispatch | `platform/lib/dev_orchestrator/runs.ex`, `runs/{run,attempt,event,failure_budget}.ex` | `claim(executor)`, `renew(executor, lease)`, `append_event(executor, lease, event)` |
| Delivery | `platform/lib/dev_orchestrator/delivery/{outbox,worker,verification}.ex` | Verify committed PR, transactionally finalize, independently deliver reports |
| Connector | `connector/src/{cli,config,api,journal,worker,workspace,codex,publisher}.ts` | Versioned JSON protocol, local allowlist, fenced execution, redacted events |
| Web | `platform/lib/dev_orchestrator_web/live/{project,connection,executor,run}_live/` | Every route and subscription uses authenticated Scope |

### Task 1: Working tenant foundation and project UI

**Files:** scaffold `platform/`; create the identity/project files above; migrations under `platform/priv/repo/migrations/`; tests `platform/test/dev_orchestrator/{accounts,projects}_test.exs` and `platform/test/dev_orchestrator_web/live/project_live_test.exs`; root `README.md`, `.gitignore`, `AGENTS.md`.

**Interfaces:** Produces `Scope`, organization membership, `Projects.get_project(scope, id)`, `Projects.create_project(scope, attrs)` and versioned project snapshots. Unauthorized lookups return `{:error, :not_found}`; privileged mutations return `{:error, :forbidden}`.

- [ ] Write tests for two users' project isolation, guessed IDs, member/owner permissions, unverified email, session rotation and invalid branch/repository configuration. Assert the second user's project cannot be read, edited or subscribed to.
- [ ] Run `cd platform && mix test test/dev_orchestrator/projects_test.exs test/dev_orchestrator_web/live/project_live_test.exs`; confirm the relevant new assertions fail before implementation.
- [ ] Build the Phoenix application and supported generated authentication flow; add organization scope, tenant foreign keys, owner checks and Project CRUD. Use a development mailbox without modifying existing email settings.
- [ ] Run the focused tests and `mix format --check-formatted`; manually check registration, verification, sign-in, project creation and empty project pages on port 4100.
- [ ] Commit `feat(platform): add authenticated tenant-scoped projects` with setup instructions and tests.

### Task 2: Real project-scoped service connections

**Files:** connection files above; `platform/lib/dev_orchestrator_web/controllers/{oauth,github_installation,webhook}_controller.ex`; migrations for grants, OAuth state and webhook receipts; `platform/test/dev_orchestrator/connections_test.exs`, `platform/test/dev_orchestrator_web/controllers/oauth_controller_test.exs`.

**Interfaces:** Consumes `Scope` and project lookup. Produces `Connections.start_oauth(scope, provider, project_id)`, `Connections.complete_oauth(scope, provider, state, code)`, `Connections.disconnect(scope, connection_id)` and sanitized connection summaries. Provider HTTP transport is injectable only at the service boundary.

- [ ] Write tests asserting expired/reused/session-swapped OAuth state is rejected; unconfigured apps stay unconfigured; token fields never appear in read responses; installation selection cannot grant a different tenant's project; replayed valid webhooks enqueue once.
- [ ] Run the new connection/controller tests and confirm expected red results.
- [ ] Implement configured GitHub App installation access and Slack/Linear OAuth adapters using current official schemas. Encrypt stored secrets with authenticated encryption and a deployment key; scope callback state to authenticated user, organization, project and provider. Enforce owner permissions on revoke/grant.
- [ ] Run adapter tests with controlled provider HTTP responses, including malformed/denied callbacks and invalid signatures. Document operator app setup, required scopes and deployment callbacks; do not register apps automatically.
- [ ] Commit `feat(connections): add isolated GitHub Linear and Slack authorization`.

### Task 3: Executor enrollment and a safe local connector

**Files:** executor files above; `platform/lib/dev_orchestrator_web/controllers/executor_controller.ex`; `platform/test/dev_orchestrator/executors_test.exs`; `connector/package.json`, `connector/tsconfig.json`, `connector/src/{cli,config,api,journal,workspace}.ts`; `connector/test/{enrollment,workspace,journal}.test.ts`.

**Interfaces:** Consumes organization membership and project grants. Produces `Executors.enroll(code, attrs) -> {:ok, %{token: token, executor: executor}}` once, `Executors.authenticate(token)`, owner-authorized project binding, and `dev-orchestrator-connector pair --server URL --code CODE` / `run --config PATH` commands.

- [ ] Write tests for ten-minute expiry, atomic code reuse, enrollment throttling, hashed server credentials, revoked credentials, unauthorized binding, insecure remote URLs, traversal and symlink escape. Assert journal recovery and owner-only credential-file permissions.
- [ ] Run `cd platform && mix test test/dev_orchestrator/executors_test.exs` and `cd connector && npm test`; confirm relevant failures before implementation.
- [ ] Implement one-use pairing, project binding, revocation and authenticated health reporting. Connector configuration requires user-approved canonical roots/repositories and stores tokens only in its own directory. Restrict plaintext HTTP to loopback development.
- [ ] Verify two connector identities cannot exchange project bindings; run connector filesystem tests using temporary repositories. Do not enroll against the user's current Symphony runtime.
- [ ] Commit `feat(executors): add scoped enrollment and local connector`.

### Task 4: Durable dispatch, concurrency and reconnect reconciliation

**Files:** run files above; `platform/lib/dev_orchestrator_web/controllers/run_event_controller.ex`; migrations for runs, snapshots, attempts and events; `platform/test/dev_orchestrator/runs_test.exs`; `connector/src/worker.ts`; `connector/test/worker.test.ts`.

**Interfaces:** Consumes authenticated executor bindings. `Runs.claim(executor)` returns `{:ok, lease_payload}` or `:empty`; lease payload includes run ID, attempt ID, generation, immutable snapshot and expiry. `Runs.renew/2` and `Runs.append_event/3` validate identity, project, generation, deadline and event sequence. `Runs.reconcile/3` never implicitly grants a new execution.

- [ ] Write concurrent database tests proving only one lease per task, bounded project concurrency, ignored duplicate events, rejected stale generations and cross-tenant payloads. Write fake-clock connector tests for lost final acknowledgement and agent shutdown before lease expiry.
- [ ] Run the dispatch/worker tests and observe expected failures.
- [ ] Implement transactional claims, fencing and idempotent event ingestion. Persist snapshots and journal state before acknowledging. Expired active work becomes `waiting_for_executor` until explicit reconciliation; queued work stays queued while executors are offline.
- [ ] Add task-lifecycle error fingerprints/counts with third-equivalent-error cancellation; test different errors, successful unrelated events, capacity waits and restart recovery. Test configuration edits do not mutate an active snapshot.
- [ ] Run both suites and commit `feat(runs): add fenced durable dispatch and recovery`.

### Task 5: Real Codex execution and trusted Git publication

**Files:** `connector/src/{codex,publisher,worker,workspace}.ts`; `connector/test/{codex,publisher,workspace}.test.ts`; protocol documentation `docs/protocol.md`.

**Interfaces:** Consumes lease snapshots and local allowlist. `CodexSession.start(workspace, policy)` manages its own official app-server process; `run(prompt)` emits sanitized typed events; `stop()` terminates the agent process tree. `Publisher.publish(context, title, body)` returns repository, head/base, SHA and PR URL without exposing credentials to the agent.

- [ ] Write protocol tests for initialize/thread/turn completion, expired auth, malformed JSON, unexpected EOF, command failure events and cancellation. Write real temporary Git tests proving unapproved branches/bases are rejected and malicious local Git hooks/config never execute in the trusted publisher context.
- [ ] Run `cd connector && npm test` and confirm the missing behavior fails.
- [ ] Inspect the existing Symphony app-server/publisher implementation read-only. Implement the protocol adapter and project-scoped sandbox launch using the current official schema. Use the installed customer's CLI/login; do not reuse desktop conversations or upload login material. Block unsupported sandbox capabilities.
- [ ] Implement isolated task checkouts, issue-branch commits and host-authenticated publishing with no force push or merge. Preserve working files when publication fails; status/reconciliation reuses an existing matching PR. Do not modify global Git configuration.
- [ ] Verify local process/Git tests and a real read-only provider-account health check only if authorized for the evaluation; commit `feat(connector): execute local Codex tasks and publish verified branches`.

### Task 6: End-to-end Linear intake, PR verification and Slack results

**Files:** `platform/lib/dev_orchestrator/intake/linear.ex`, delivery files above; `platform/test/dev_orchestrator/{intake,delivery}_test.exs`; delivery migrations; run-detail LiveViews.

**Interfaces:** Consumes project connections and run events. `Intake.Linear.accept(project, issue)` deduplicates source work; `Delivery.Verification.verify(project, result)` validates PR identity and head commit; transactional finalization inserts an outbox record keyed by run/lifecycle/outcome. Delivery workers never claim development tasks.

- [ ] Write tests for a correctly published PR in `In Review`, mismatched SHA/repo/base, no-change completion, duplicate Linear deliveries, third-failure reports, and GitHub success followed by Slack timeout. Assert task success remains success and no extra development attempt appears.
- [ ] Run the intake/delivery tests and confirm red failures.
- [ ] Wire Linear intake, real GitHub verification, review-state update and Slack final/blocker reporting. Redact errors, enforce event-size limits and do not store raw command transcripts. Retry explicit Slack rejections within a bounded policy; hold ambiguous delivery for recovery.
- [ ] Verify disconnected/revoked connections are actionable blockers; show actual delivery status and retry counts in the web UI. Run the combined server/connector suites.
- [ ] Commit `feat(delivery): connect task intake to verified PR and Slack outcomes`.

### Task 7: Deployable evaluation and regression verification

**Files:** `platform/Dockerfile`, `compose.yaml`, `.github/workflows/ci.yml`, `README.md`, `docs/deployment.md`, `docs/security.md`, `docs/evaluation.md`; integration/regression tests.

**Interfaces:** Produces separate migration/start commands, port-4100 local evaluation, production-required secret validation and documented readiness status. Compose config references environment variables without embedding credentials.

- [ ] Write tests for missing production secrets, unhealthy database readiness, malformed/oversized events and server/connector restart recovery. Add browser checks for authenticated navigation, project setup and disconnected/error states.
- [ ] Observe failing configuration/recovery checks before implementing deployment guards.
- [ ] Implement container startup, migrations, health/readiness probes and documented backup/restore/credential rotation procedures. Add CI for Elixir and connector tests, type checking and formatting. Keep real provider smoke tests opt-in.
- [ ] Run the full server/connector suites, type checks, formatting, build and UI verification. Record exact unavailable checks or failures. Never label an untested deployment or unconfigured provider as working.
- [ ] Commit `chore(deploy): package isolated cloud evaluation with verification`.

### Task 8: Publish the verified repository

**Files:** review the complete tracked repository, lockfiles, docs and ignore rules.

**Interfaces:** User-authorized Git destination `https://github.com/juan01-ctrl/dev-orchestrator.git`, branch `main`; no force push and no changes to the old repository remote.

- [ ] Inspect destination refs with `git ls-remote` and local `git status`. If the destination is nonempty, preserve its history and reconcile before publishing; never overwrite it blindly.
- [ ] Review tracked content for secrets, runtime data, local login files and customer source; check `git diff --check`, committed work-unit history and complete validation results.
- [ ] Initialize or attach only the new checkout as appropriate; configure its own origin and `main` without modifying other checkouts. Do not use the supplied literal `first commit` message; retain Conventional Commit work units.
- [ ] Push `main` to the authorized destination without force. Verify local HEAD equals the remote branch HEAD and report the exact commit and tests; push permission/network failure remains explicit incomplete work.

## Plan Review

The implementation is intentionally phased, but success means the integrated
evaluation works, not just a scaffold or attractive dashboard. Connection setup
needs operator-supplied OAuth/App configuration; missing external configuration
must be reported honestly while remaining offline/testable paths are completed.

Recommended execution is native: one agent implements these dependent interfaces
in this session, with per-task verification and review before publication. No
subagents, cloud deployment or provider-account registration are requested.

Native execution was approved. See `docs/implementation-status.md` for the source
checkpoint, verification evidence and remaining gates. Do not mark unchecked tasks
complete or publish this as a completed product based on source-only verification.
