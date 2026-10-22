# Premium Runtime Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the hosted control plane and local Codex app-server executor to feature parity with the previous local Symphony flow while retaining secure multi-tenant execution and verified GitHub delivery.

**Architecture:** Linear uses a generic signed webhook backed by a durable inbox and reconciliation loop. A persistent, bidirectional Codex app-server adapter runs inside a supervised local slot pool, emits sanitized typed events, and resumes threads after interruption. PostgreSQL remains the durable source of truth while Phoenix PubSub supplies low-latency UI updates.

**Tech Stack:** Elixir/Phoenix/LiveView/PostgreSQL, Node.js 22/TypeScript, official Codex app-server JSON-RPC, GitHub App, Linear and Slack OAuth, ExUnit and Node test runner.

**Spec:** `docs/superpowers/specs/2026-10-22-premium-runtime-parity-design.md`

## Global Constraints

- Preserve all existing tenant, executor-binding, lease-generation, event-sequence, GitHub-token, and independent PR-verification boundaries.
- Do not expose source code, raw command output, private reasoning, secrets, tokens, local paths, or provider payloads in cloud events.
- Do not require a pre-existing repository clone, global Git configuration, or GitHub CLI login.
- Routine in-policy work must not request approval; missing context and out-of-policy access must produce explicit durable states.
- Use only exact deployment-configured model IDs; never silently substitute an unsupported model.
- Keep the current service usable after every task and use conventional commits without AI attribution.
- Preserve unrelated changes already present in the working tree.

## Review Focus

- A connector crash after a command but before event acknowledgement must not execute the command twice; Task 6 adds crash-boundary and resume tests.
- A forged organization ID, connection ID, delivery ID, or executor event must not cross tenant boundaries; Tasks 2 and 4 add negative authorization tests.
- Replayed and out-of-order app-server notifications must produce one ordered public timeline; Tasks 1 and 4 add cursor and sequence tests.
- A webhook received while Linear is slow or unavailable must still return promptly and later reconcile correctly; Task 2 adds timeout and recovery tests.
- Network and permission requests must neither grant broader host access nor block routine dependency work; Task 5 adds capability-policy tests.

---

## File and interface map

| Unit | Primary files | Responsibility |
|---|---|---|
| App-server protocol | `connector/src/app-server/{client,events,requests,session}.ts` | JSON-RPC lifecycle, profile negotiation, requests, typed events, thread resume |
| Local orchestration | `connector/src/{worker,pool,journal,activity}.ts` | Slot scheduling, durable recovery, deadlines, event emission |
| Linear intake | `platform/lib/dev_orchestrator/intake/{linear,inbox,reconciler}.ex` | Fast webhook persistence, async normalization, lifecycle reconciliation |
| Run lifecycle | `platform/lib/dev_orchestrator/runs.ex`, `platform/lib/dev_orchestrator/runs/{event,lifecycle}.ex` | Lifecycle generations, cancellation, clarification, accepted event broadcast |
| Live timeline | `platform/lib/dev_orchestrator_web/live/{dashboard_live,dashboard_components}.ex` | Initial history load, PubSub updates, safe professional rendering |
| Policy | `platform/lib/dev_orchestrator/execution_policy.ex`, connector snapshot types | Model/effort/capability decision and validation |
| Delivery/operations | `platform/lib/dev_orchestrator/delivery/{outbox,worker,supervisor}.ex` | Concurrent idempotent delivery, telemetry, final reporting |

### Task 0: Freeze a trustworthy baseline

**Files:**
- Modify: `platform/test/offline.exs`
- Modify: `docs/implementation-status.md`
- Test: existing platform and connector suites

**Interfaces:**
- Consumes: current uncommitted repository-bootstrap, Slack-channel, and activity-stream work.
- Produces: a reviewable baseline commit and a green portable offline test entry point.

- [ ] **Step 1: Inspect and classify every existing modified/untracked file** against its originating feature; do not discard or fold unrelated work into parity commits.
- [ ] **Step 2: Update `platform/test/offline.exs`** to load the current provider modules, including `DevOrchestrator.Connections.GitHub`, without weakening assertions.
- [ ] **Step 3: Run `cd connector && npm run check && npm test`**; expect typecheck success and all connector tests passing.
- [ ] **Step 4: Run `cd platform && mise exec -- elixir test/offline.exs`**; expect zero failures.
- [ ] **Step 5: Run `cd platform && mise exec -- mix test`** in an environment that permits the local test listener; expect zero failures or record the exact environmental blocker without claiming success.
- [ ] **Step 6: Update the implementation checkpoint** with commands, counts, known environmental constraints, and current unsupported behavior.
- [ ] **Step 7: Commit the already-built baseline separately** as `feat: complete managed executor bootstrap` after reviewing its diff.

### Task 1: Implement a bidirectional persistent app-server client

**Files:**
- Create: `connector/src/app-server/client.ts`
- Create: `connector/src/app-server/events.ts`
- Create: `connector/src/app-server/requests.ts`
- Create: `connector/src/app-server/session.ts`
- Modify: `connector/src/codex.ts` to become a compatibility facade or remove it after callers migrate
- Modify: `connector/src/types.ts`
- Test: `connector/test/app-server/{client,events,requests,session}.test.ts`

**Interfaces:**
- Consumes: workspace path, prompt, immutable execution policy, optional persisted `threadId`, and an abort signal.
- Produces: `AppServerSession.open(options)`, `session.runTurn(prompt)`, `session.resume(threadId)`, `session.respond(requestId, response)`, `session.close()`, and `PublicExecutionEvent` values.

- [ ] **Step 1: Write failing protocol tests** for initialize-once, `permissionProfile/list`, `thread/start`, `thread/resume`, multiple `turn/start` calls, deltas, completion, warning, token usage, malformed JSON, unexpected EOF, cancellation, and request timeout.
- [ ] **Step 2: Write failing server-request tests** for in-policy command/file approval, out-of-policy denial, missing-context input, permission request, MCP elicitation, and unknown request methods.
- [ ] **Step 3: Implement a typed line-delimited JSON-RPC client** with independent request deadlines, bounded stderr capture, process-tree shutdown, and no generic rejection of all server requests.
- [ ] **Step 4: Implement permission-profile discovery and request routing**; auto-resolve only requests explicitly authorized by the immutable policy and surface clarification or blocker results for everything else.
- [ ] **Step 5: Implement durable thread start/resume and multi-turn execution** while treating only `turn/completed` with a successful status as completion.
- [ ] **Step 6: Run `cd connector && npm run check && npm test`**; expect all protocol and existing connector tests to pass.
- [ ] **Step 7: Commit** as `feat(connector): support persistent app server sessions`.

### Task 2: Replace per-connection Linear webhooks with durable generic intake

**Files:**
- Create: `platform/lib/dev_orchestrator/intake/inbox.ex`
- Create: `platform/lib/dev_orchestrator/intake/processor.ex`
- Modify: `platform/lib/dev_orchestrator/intake/linear.ex`
- Modify: `platform/lib/dev_orchestrator_web/controllers/webhook_controller.ex`
- Modify: `platform/lib/dev_orchestrator_web/router.ex`
- Create: a forward-only migration for inbox rows and delivery metadata
- Test: `platform/test/dev_orchestrator/intake/{inbox,linear}_test.exs`
- Test: `platform/test/dev_orchestrator_web/controllers/webhook_controller_test.exs`

**Interfaces:**
- Consumes: raw signed request body, `Linear-Signature`, `Linear-Timestamp`, and `Linear-Delivery`.
- Produces: `Inbox.accept_linear(headers, raw_body) :: {:ok, :accepted | :duplicate} | {:error, atom}` and asynchronous `Processor.process(id)`.

- [ ] **Step 1: Write failing controller tests** proving the generic endpoint rejects invalid/stale signatures and oversized bodies, deduplicates `Linear-Delivery`, ignores query-string identity, and responds without calling Linear GraphQL.
- [ ] **Step 2: Write failing processor tests** for organization-to-connection routing, multiple projects in one organization, revoked connections, team/project/state filtering, provider timeout, and replay.
- [ ] **Step 3: Add a bounded durable inbox table** with unique provider/delivery ID, organization routing metadata, state, attempts, next-attempt time, and redacted failure category.
- [ ] **Step 4: Implement `POST /api/v1/webhooks/linear`** to verify and persist only; retain the old connection-ID route temporarily as a logged compatibility path without documenting it for new installations.
- [ ] **Step 5: Move Linear GraphQL and run creation into `Processor`** with bounded retries, jittered backoff, and no external call inside the webhook database transaction.
- [ ] **Step 6: Update connection UI and documentation** to show one provider-owned webhook URL and remove customer-facing connection-ID instructions.
- [ ] **Step 7: Run targeted controller/intake tests and the full platform suite**; expect zero failures.
- [ ] **Step 8: Commit** as `feat(linear): add durable generic webhook intake`.

### Task 3: Add Linear reconciliation and explicit issue lifecycles

**Files:**
- Create: `platform/lib/dev_orchestrator/intake/reconciler.ex`
- Create: `platform/lib/dev_orchestrator/runs/lifecycle.ex`
- Modify: `platform/lib/dev_orchestrator/intake/linear.ex`
- Modify: `platform/lib/dev_orchestrator/runs.ex`
- Modify: `platform/lib/dev_orchestrator/background.ex`
- Create: a forward-only migration for reconciliation cursors and lifecycle activations
- Test: `platform/test/dev_orchestrator/intake/reconciler_test.exs`
- Test: `platform/test/dev_orchestrator/runs_lifecycle_test.exs`

**Interfaces:**
- Consumes: normalized issue snapshots and a per-connection `updatedAt` cursor.
- Produces: `Lifecycle.apply_issue(project, issue) :: {:ok, :unchanged | :created | :cancelled | :rework}` and `Reconciler.tick(connection_id)`.

- [ ] **Step 1: Write failing lifecycle tests** for first activation, duplicate active update, terminal cancellation, completed issue reactivation, concurrent webhook/reconcile delivery, and safe existing branch/PR reuse.
- [ ] **Step 2: Write failing reconciliation tests** for paginated `updatedAt` queries, cursor advancement only after success, rate limiting, revoked OAuth, downtime backfill, and startup recovery.
- [ ] **Step 3: Replace issue-global deduplication with lifecycle activation keys** while preserving one active run per project/issue lifecycle.
- [ ] **Step 4: Implement terminal-state cancellation and rework creation** without mutating immutable prior run snapshots.
- [ ] **Step 5: Implement scheduled rate-aware reconciliation** with a startup pass and configurable interval; webhook remains the fast path.
- [ ] **Step 6: Run targeted lifecycle/reconciler tests and the full platform suite**; expect zero failures.
- [ ] **Step 7: Commit** as `feat(linear): reconcile issue lifecycles`.

### Task 4: Stream the complete safe execution timeline

**Files:**
- Modify: `connector/src/activity.ts`
- Modify: `connector/src/worker.ts`
- Modify: `platform/lib/dev_orchestrator/runs/event.ex`
- Modify: `platform/lib/dev_orchestrator/runs.ex`
- Modify: `platform/lib/dev_orchestrator_web/live/dashboard_live.ex`
- Modify: `platform/lib/dev_orchestrator_web/live/dashboard_components.ex`
- Test: `connector/test/activity.test.ts`
- Test: `platform/test/dev_orchestrator/event_test.exs`
- Test: `platform/test/dev_orchestrator_web/live/project_live_test.exs`

**Interfaces:**
- Consumes: `PublicExecutionEvent` from Task 1 and accepted fenced run events.
- Produces: `Runs.subscribe(run_id)`, PubSub topic `run:<id>`, ordered persisted events, and reconnect-safe LiveView rendering.

- [ ] **Step 1: Write failing connector tests** for phase, plan summary, bounded agent delta, command summary, file summary, validation, warning, usage, clarification, blocker, candidate, and completion mapping; assert secret/path/raw-output redaction and size limits.
- [ ] **Step 2: Write failing server tests** for event validation, sequence ordering, duplicate acknowledgement, PubSub broadcast only after commit, and cross-tenant subscription isolation.
- [ ] **Step 3: Extend the versioned event schema and connector mapper** without transmitting reasoning or raw command streams.
- [ ] **Step 4: Broadcast accepted events after database commit** and add `Runs.subscribe/1` for authorized LiveView processes.
- [ ] **Step 5: Replace five-second run polling with PubSub** while keeping database history for mount/reconnect and a low-frequency connection-health refresh.
- [ ] **Step 6: Render a professional compact timeline** with meaningful phase labels, elapsed time, current action, validation state, clarification controls, and final PR link.
- [ ] **Step 7: Run connector and platform event/LiveView suites**; expect zero failures.
- [ ] **Step 8: Commit** as `feat(runs): stream live execution activity`.

### Task 5: Restore task-aware model and capability policy

**Files:**
- Create: `platform/lib/dev_orchestrator/execution_policy.ex`
- Modify: `platform/lib/dev_orchestrator/projects.ex`
- Modify: project configuration LiveView fields in `platform/lib/dev_orchestrator_web/live/dashboard_live.ex`
- Modify: `connector/src/types.ts`
- Modify: `connector/src/worker.ts`
- Modify: app-server request/profile files from Task 1
- Test: `platform/test/dev_orchestrator/execution_policy_test.exs`
- Test: `connector/test/app-server/requests.test.ts`
- Test: `connector/test/worker.test.ts`

**Interfaces:**
- Consumes: issue type/title/labels/state, project policy, deployment-supported model catalog, and executor capabilities.
- Produces: immutable `%{class, model, effort, permissions, network}` inside the lease snapshot.

- [ ] **Step 1: Write failing policy tests** mapping routine work to configured Luna/low and planning, review, bug, fix, security, and rework to configured Sol/high; test explicit valid override and unsupported model rejection.
- [ ] **Step 2: Write failing capability tests** for routine workspace/Git access, project-scoped skills, approved registry/documentation egress, denied credential paths, arbitrary host paths, deployment operations, and unrelated repositories.
- [ ] **Step 3: Implement server-owned policy classification and a validated model catalog**; replace the free-form model override UI with deployment-supported choices and “Automatic”.
- [ ] **Step 4: Include the immutable execution policy in claims** and advertise executor capabilities during heartbeat so incompatible work remains queued with an actionable reason.
- [ ] **Step 5: Apply negotiated permission profiles and bounded network policy locally**; do not pass GitHub installation tokens or platform OAuth credentials to app-server.
- [ ] **Step 6: Run policy, request-broker, and worker tests plus both full suites**; expect zero failures.
- [ ] **Step 7: Commit** as `feat(policy): route models and execution capabilities`.

### Task 6: Add clarification, parallel slots, and resilient recovery

**Files:**
- Create: `connector/src/pool.ts`
- Modify: `connector/src/cli.ts`
- Modify: `connector/src/journal.ts`
- Modify: `connector/src/worker.ts`
- Modify: `connector/src/types.ts`
- Modify: `platform/lib/dev_orchestrator/runs.ex`
- Modify: `platform/lib/dev_orchestrator_web/controllers/executor_controller.ex`
- Modify: Slack delivery modules for clarification messages
- Test: `connector/test/{pool,journal,worker}.test.ts`
- Test: `platform/test/dev_orchestrator/{runs,clarification}_test.exs`

**Interfaces:**
- Consumes: executor slot capacity, lease claims, durable journals, and clarification responses.
- Produces: `ExecutionPool.run(capacity, signal)`, per-slot recovery, `Runs.request_clarification/3`, and `Runs.answer_clarification/3` that resumes the same thread.

- [ ] **Step 1: Write failing pool tests** proving capacity two executes two projects concurrently, respects project limits, isolates cancellation, renews each lease, and applies backpressure.
- [ ] **Step 2: Write failing recovery tests** for stale live/dead PID locks, crash before/after command completion, pending event replay, preserved worktree, thread resume, and duplicate-publication prevention.
- [ ] **Step 3: Write failing clarification tests** for one open request, authorized response, Slack/UI delivery, expiry, duplicate answers, and same-thread resume.
- [ ] **Step 4: Implement a supervised local slot pool** with independent app-server processes, journals, renewers, silence timeouts, command timeouts, and configurable total deadlines.
- [ ] **Step 5: Replace manual stale-lock deletion** with exact lock ownership, PID liveness checks, atomic recovery, and refusal when the owning process is alive.
- [ ] **Step 6: Implement durable clarification state and response delivery**; routine authorized actions never enter this path.
- [ ] **Step 7: Run connector concurrency/recovery tests and platform clarification/run tests**; expect zero failures.
- [ ] **Step 8: Commit** as `feat(executors): add parallel resilient execution`.

### Task 7: Scale final delivery and add production diagnostics

**Files:**
- Create: `platform/lib/dev_orchestrator/delivery/supervisor.ex`
- Modify: `platform/lib/dev_orchestrator/delivery/{outbox,worker}.ex`
- Modify: `platform/lib/dev_orchestrator/background.ex`
- Modify: `platform/lib/dev_orchestrator/application.ex`
- Modify: `platform/lib/dev_orchestrator_web/controllers/health_controller.ex`
- Modify: `docs/{deployment,evaluation,protocol,security,connections,implementation-status}.md`
- Test: `platform/test/dev_orchestrator/delivery_test.exs`
- Test: `platform/test/dev_orchestrator/operations_test.exs`

**Interfaces:**
- Consumes: finalized lifecycle outcomes and provider-specific outbox jobs.
- Produces: concurrent idempotent delivery, bounded retry schedules, correlation-aware telemetry, readiness state, and operator runbooks.

- [ ] **Step 1: Write failing delivery tests** for concurrent claims, Slack/Linear transient rejection, ambiguous timeout, duplicate finalization, poison jobs, provider isolation, and exactly-once observable report behavior.
- [ ] **Step 2: Implement a supervised bounded delivery pool** using `FOR UPDATE SKIP LOCKED`, provider-specific retry policy, next-attempt timestamps, and dead-letter/ambiguous inspection states.
- [ ] **Step 3: Add structured telemetry** for webhook lag, queue wait, lease health, executor capacity, app-server turns, publication, reconciliation, and outbox delivery without sensitive fields.
- [ ] **Step 4: Extend readiness and operator diagnostics** to distinguish database, provider configuration, executor availability, queue degradation, and delivery degradation.
- [ ] **Step 5: Update all setup and migration documentation** for the generic Linear webhook, connector upgrade, model catalog, network policy, capacity, rollback, and incident recovery.
- [ ] **Step 6: Run the full platform and connector suites**; expect zero failures.
- [ ] **Step 7: Commit** as `feat(operations): harden delivery and diagnostics`.

### Task 8: Prove parity through authorized end-to-end scenarios

**Files:**
- Modify: `docs/evaluation.md`
- Modify: `docs/implementation-status.md`
- Add only narrowly scoped automated contract fixtures required by the scenarios

**Interfaces:**
- Consumes: completed Tasks 0–7 and owner-authorized test integrations.
- Produces: recorded, reproducible evidence for the acceptance criteria in the spec.

- [ ] **Step 1: Run the complete local automated suite**: `cd connector && npm run check && npm test`; `cd platform && mise exec -- mix test`; require zero failures.
- [ ] **Step 2: Run a simple no-dependency Linear issue** and verify webhook-to-dashboard latency, live events, commit, PR, Linear review transition, and Slack result.
- [ ] **Step 3: Run a dependency-install task** and verify only the configured network destinations are reachable.
- [ ] **Step 4: Run two simultaneous issues** and verify concurrent isolated worktrees, correct branches/PRs, and ordered event streams.
- [ ] **Step 5: Interrupt and restart the connector mid-turn** and verify journal reconciliation, thread resume, no duplicate side effects, and correct final report.
- [ ] **Step 6: Suppress/replay a Linear webhook, perform a rework transition, and move an active issue terminal**; verify reconciliation, one lifecycle per activation, PR reuse, and cancellation.
- [ ] **Step 7: Trigger missing context** and verify one Slack/UI clarification resumes the same run without routine approval prompts.
- [ ] **Step 8: Record sanitized timestamps and results in `docs/implementation-status.md`**; list any scenario not executed rather than marking it complete.
- [ ] **Step 9: Commit** as `test: verify premium runtime parity`.

## Rollout and owner actions

No owner-side integration change is required before Tasks 0–7 are complete. During
Task 8, the service owner must:

1. Configure the Linear OAuth application's webhook URL as
   `PUBLIC_URL/api/v1/webhooks/linear`, subscribe to Issue create/update events, and
   copy the webhook signing secret into the server secret store.
2. Reconnect the existing Linear test organization once if Linear does not provision
   the newly configured app webhook retroactively.
3. Keep one local connector host signed into the intended Codex subscription and
   install/run the upgraded connector build when provided.
4. Confirm the GitHub App remains installed for the test repository and the Slack bot
   is invited to the selected test channel.
5. Create the seven bounded acceptance issues requested by Task 8 and authorize their
   use for the smoke test. No production repository or customer workspace is needed.

No GitHub or Slack reauthorization is expected unless implementation discovers that
the existing OAuth scopes are insufficient. Any scope expansion must stop for explicit
owner approval before configuration changes are made.

## Execution gates

- **Gate A — Baseline:** Task 0 green and current work preserved.
- **Gate B — Core parity:** Tasks 1–3 green; app-server resume and Linear correctness proven.
- **Gate C — Premium experience:** Tasks 4–6 green; live events, policy, clarification, and parallelism proven.
- **Gate D — Operational readiness:** Task 7 green; delivery and observability proven.
- **Gate E — Release candidate:** Task 8 evidence complete with no unresolved P0/P1 defect.

