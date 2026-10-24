# Workflow Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make attempts, validation, task revisions, human pauses, and PR repairs durable and bounded.

**Architecture:** Extend existing runs, inbox/outbox records, and connector journals.
Use supervised bounded server workers; keep provider operations outside state locks.
Keep explicit user input revisions and one writer per execution branch.

**Tech Stack:** Elixir/Phoenix/Ecto/PostgreSQL; TypeScript/Node; Codex app-server; Slack/Linear/GitHub.

**Spec:** `docs/superpowers/specs/2026-10-24-workflow-reliability-design.md`

## Global Constraints

- Preserve tenant scopes, connection grants, lease generation/lifecycle fencing, and exact-host policy.
- Preserve unrelated working-tree edits and the established local checkout workflow.
- Do not publish, deploy, change credentials, or enable live provider subscriptions.
- Retain model identities; use `implement` and `investigate` as explicit task modes.
- Keep existing branch identity for previously leased attempts; version fresh attempts.
- Provider smoke tests remain opt-in. Report infrastructure-blocked checks explicitly.

## Review Focus

- Old and new connector versions must not reset retained branches or reject an already active attempt.
- A changed package script must not silently satisfy a previously pinned validation contract.
- Concurrent Slack correction/confirmation must never create an issue from an obsolete draft.
- Answers after process restart must resume a preserved question without reusing dead JSON-RPC IDs.
- Duplicate or old-head PR observations must never enqueue duplicate repairs or overwrite human work.

---

### Task 1: Isolate fresh attempts and freeze snapshots

**Files:** `connector/src/repository.ts`, `platform/lib/dev_orchestrator/runs.ex`,
`runs/event.ex`, `delivery/verification.ex`, repository/event/verification/runs tests.

**Interfaces:** snapshot `task_branch` is authoritative; legacy snapshots fall back
to `task/<run>`. A fresh snapshot uses `task-attempts/<run>/attempt-<lifecycle>`.

- [ ] Add regressions for two lifecycles after a push and configuration updates between automatic retries.
- [ ] Run targeted tests and observe the existing branch/snapshot defect.
- [ ] Preserve non-null snapshots and use the authoritative branch in checkout, sanitization, and verification.
- [ ] Verify resuming preserves head, fresh attempts remain publishable, and legacy branches remain valid.

### Task 2: Pin validation and explicit task modes

**Files:** connector `environment.ts`, `worker.ts`, `types.ts`, `journal.ts`,
platform `runs.ex`, `execution_policy.ex`, dashboard, migration and focused tests.

**Interfaces:** run `mode` defaults to `implement`; snapshots carry it. The journal
stores its initial `EnvironmentPlan`; validation exposes `passed/failed/not_run`.

- [ ] Test missing checks, removed scripts, pinned plans across recovery, and investigation without publication.
- [ ] Preserve the initial plan, detect changed command definitions, and expose review-required validation.
- [ ] Enforce investigation permissions and report-only completion at both publication and server boundaries.
- [ ] Verify normal implementation remains compatible and document configuration review behavior.

### Task 3: Propagate intake failures before receipts and cursors

**Files:** intake `inbox.ex`, `reconciler.ex`, `lifecycle.ex`, intake tests.

**Interfaces:** application results are `{:ok, value}` or `{:error, reason}`;
only full successful application permits receipt/cursor advancement.

- [ ] Test returned lifecycle errors during fan-out and multi-page scans.
- [ ] Collect every result, preserve the failed page cursor, and retain the scan watermark across pages.
- [ ] Verify replay remains idempotent and scope changes trigger backfill.

### Task 4: Supervise independent bounded background workers

**Files:** `background.ex`, `application.ex`, new focused worker module and tests;
connector `pool.ts` and its existing tests for pre-aborted signals.

**Interfaces:** each worker owns one timer and at most one monitored task;
maintenance, inbox, Slack preparation/creation, delivery, reconciliation are independent.

- [ ] Test slow/abruptly terminated work and already cancelled connector startup.
- [ ] Split workers with monitored task ownership, bounded timeouts, and restart-safe durable claims.
- [ ] Verify lease maintenance continues during provider stalls and no overlapping worker job starts.

### Task 5: Correct Slack drafts conversationally

**Files:** intake `slack_drafts.ex`, `task_draft.ex`, OpenAI structuring adapter,
Slack webhook handling, additive migration and tests; connections/evaluation docs.

**Interfaces:** draft `revision` and `requested_revision` fence processing;
confirmation action contains draft ID plus displayed revision. Legacy buttons remain
valid only for an unchanged first revision.

- [ ] Test text/audio corrections, author/workspace/thread isolation, duplicates, and stale buttons.
- [ ] Route mentioned thread replies to the original open draft; queue revisions using stored request context.
- [ ] Generate from previous accepted input and correction; invalidate old confirmations before generation.
- [ ] Verify correction/confirmation races, durable retries, and one eventual Linear creation.

### Task 6: Release slots during human waits and resume answers

**Files:** platform `runs.ex`, `runs/clarification.ex`, migration and dashboard;
connector worker/session/journal/API and focused tests.

**Interfaces:** durable `awaiting_input` state stores continuation identity;
an authorized answer queues the same attempt under a new generation, retaining branch.

- [ ] Test pause, process loss, late answer, duplicate answer, cancellation, and active-budget preservation.
- [ ] Checkpoint the question, conversation/workspace references, and remaining execution budget.
- [ ] Stop the current session and release the lease; resume through a new turn carrying the matched answer.
- [ ] Verify stale executors cannot publish or consume answers from another continuation.

### Task 7: Observe PR feedback and queue bounded repairs

**Files:** new PR observer/pure feedback classifier, run continuation logic,
GitHub adapter, additive migration and focused tests; protocol/evaluation docs.

**Interfaces:** observations include PR/head/source identity and a stable fingerprint;
only current-head actionable feedback creates an implementation continuation.

- [ ] Test failed CI, requested changes, duplicate/out-of-order feedback, changed human head, and repair exhaustion.
- [ ] Persist observations outside provider calls and enqueue one repair per accepted current-head batch.
- [ ] Resume the preserved branch without resetting it; run pinned checks and publish a normal fast-forward update.
- [ ] Surface review/CI state independently of delivery success; require human merge.

### Task 8: Align deployment guidance and final verification

**Files:** `compose.cloud.yaml`, README, deployment/protocol/evaluation docs and package metadata if required.

- [ ] Align Compose with Resend and current Slack/OpenAI runtime variables and documented generic webhooks.
- [ ] Document new task modes, migration requirements, connector compatibility, pause/repair limits and activation.
- [ ] Run connector typecheck/suite, platform suite/offline suite, formatting, and diff checks.
- [ ] Run one fresh whole-change code review, fix consequential findings, and record remaining integration limitations.

## Execution ledger

- Plan authored against `fcbe22e`; user explicitly requested planning followed by execution.
- Ruling: continue in the existing feature branch/checkout used throughout this conversation;
  preserve the unrelated health-controller/webhook formatting and untracked earlier plans.
- Ruling: leave commits/push/deployment for the user's established publication workflow;
  keep each task identifiable in this ledger and its tests.
- Shared interfaces: Tasks 1/2 define branch and immutable attempt data; Tasks 6/7 preserve those
  for continuations. Task 4 provides scheduling for Tasks 5/7. Task 5 revisions apply only before
  Linear creation; Task 6 answers apply during execution. No new provider configuration is enabled.
- Progress: Tasks 1–4 implemented; targeted RED→GREEN tests and connector suite 107/107,
  server offline checks 85/85 passed. PostgreSQL integration remains pending in this environment.
- Ruling: protocol capability `workflow_version: 2` gates new attempts and investigation;
  existing snapshots retain legacy branch identities. Upgrade the connector before fresh retries.
- Progress: Task 5 revision handling implemented; verification in progress. Corrections start
  after the first proposal exists, and additional pending text corrections are retained within the bounded input.
- Progress: Task 6 implemented with per-attempt private checkpoints shared across slots,
  24-hour questions, preserved remaining compute budget and generation-fenced answer continuations.
  Targeted connector journal/worker tests passed; SQL integration still requires PostgreSQL access.
- Progress: Tasks 7–8 source implementation and deployment guide complete; connector
  typecheck and suite 110/110 and offline checks 90/90 passed before final review.
  Full `mix test` attempted and blocked by PostgreSQL localhost:5433 `:eperm`.
  New SQL test modules compile with `mix run --no-start`; this is not SQL execution.
- Final: Ruling: use `task-attempts/<run>/attempt-N`, not descendants of legacy
  `task/<run>` — Git cannot retain a ref and child refs simultaneously — costs a
  separate branch prefix; authoritative existing snapshot identities stay unchanged.
- Ruling: use a 90-second answer handoff window and a pre-request checkpoint —
  prevent an immediately answered question racing a still-stopping session — costs
  up to 90 seconds of resume latency without consuming compute budget.
- Ruling: PR repairs are owner-opt-in, Check Runs and authorized requested reviews
  only, with bounded pagination/three rounds/seven-day observation — avoids broad
  autonomous listening — legacy commit statuses need manual handling.
- Final review: one independent read-only reviewer completed the whole-change pass.
  All consequential findings received fixes: legacy ref namespace and Publisher
  compatibility; workflow-v2 snapshots excluded from legacy claims; jobs linked to
  their owning worker; pending audio retained through text corrections; reversals
  published relative to the delivered head rather than the original baseline.
- Final verification: connector typecheck and full suite 114/114; platform offline
  checks 93/93; changed Elixir files formatted and SQL-dependent test modules compile.
  Full `mix test` is NOT verified: localhost:5433 is denied with `:eperm`. An isolated
  temporary PostgreSQL attempt also failed because shared-memory creation is denied.
  Run the full database suite before publishing these changes.
- Final: fixed regression tests observed RED→GREEN for retained legacy refs,
  lifecycle publication, orphaned jobs, pending audio selection and reversal delivery.
  Added SQL regressions for legacy claim compatibility, pauses/expiry/revocation,
  intake receipts, multi-page cursors and repair deduplication; their execution is
  infrastructure-blocked here, not claimed passing.
- Final: Ruling: GitHub Check Runs already default to latest results — no synthetic
  historical-rerun workaround was added — relies on that documented API contract.
- Final: Ruling: pin command definitions, not the semantic strength of changed tests —
  human review remains mandatory — a weakened assertion still requires review.
- Final: Ruling: pre-upgrade recovered journals without pinned plans explicitly block —
  do not trust already modified definitions — requires review/fresh attempt to resume.
- Final: Ruling: real-provider recovery and SQL race guarantees remain unverified —
  do not deploy on offline evidence alone — operator database/provider checks remain.
- Final: no minor findings were deferred. No commits, pushes, npm releases, provider
  settings or deployments were performed. Connector 0.2.0 is source metadata only;
  use a locally built connector until its package is explicitly released.
- Follow-up: operator's database run passed 189/192 platform tests. The three
  failures were stale expectations: UI commands still expected connector 0.1.5,
  and the new revocation test expected cancellation instead of the established
  `blocked/authentication_required` result. Updated only these test expectations;
  revocation still prevents resuming the answer. No production behavior changed.
  Fresh connector suite 114/114, offline suite 93/93 and test-module compilation
  passed. Full platform rerun remains blocked in this environment; operator rerun required.
