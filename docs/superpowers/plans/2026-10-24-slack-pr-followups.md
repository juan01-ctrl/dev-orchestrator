# Slack PR Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. Steps use checkbox syntax.

**Goal:** Confirm text/audio Slack feedback and update the already delivered PR.
**Architecture:** Reuse Slack drafts and workflow-v2 checkpoints; persist report roots
and freeze each proposal's target. Keep provider calls outside state transactions.
**Tech Stack:** Existing Elixir/Phoenix/PostgreSQL, Slack/OpenAI/GitHub adapters.
**Spec:** `docs/superpowers/specs/2026-10-24-slack-pr-followups-design.md`

## Global Constraints

- No new Linear issues for known report threads; no new branches for continuations.
- Keep explicit mention, author/workspace/project checks and versioned confirmation.
- No force-push, automatic merge, new provider subscriptions, release or deployment.
- Preserve unrelated health-controller/webhook-test formatting and earlier untracked docs.
- Keep connector 0.2.0 compatibility; no new model or framework.

## Review Focus

- An ambiguous Slack send must not be retried as a definite rejection.
- A stale report or proposal must not update a new lifecycle or human-modified head.
- Duplicate confirmations and concurrent automatic CI repairs must serialize on the run.
- A reply after follow-up completion must create another adjustment, not a Linear task.
- An audio correction followed quickly by text must retain its pending audio input.

### Task 1: Durable report roots

**Files:** additive migration, `delivery/slack_reports.ex`, delivery worker/outbox,
Slack adapter and focused provider/integration tests.
**Interfaces:** `Slack.deliver_with_receipt/2` returns `{:ok, ts}` or existing
delivery classifications. `SlackReports.deliver/3` persists scoped thread roots.

- [x] Add failing receipt tests for success, rejection and ambiguous/malformed replies.
- [x] Add the scoped thread table, draft target columns and manual follow-up counter.
- [x] Persist acknowledged roots; reuse them for subsequent reports; retain ambiguous-send behavior.
- [ ] Run provider/offline tests and integration tests where infrastructure permits.

### Task 2: Confirmed follow-up intake and continuation

**Files:** `intake/slack_drafts.ex`, `runs/slack_followups.ex`, task draft renderer,
OpenAI bounded input, Slack action normalization/controller, focused tests.
**Interfaces:** `SlackFollowups.target/2`, `context/1`, `queue/1`; draft fields
`target_run_id`, `target_lifecycle`, `target_commit`; action IDs `apply_pr_followup`
and `cancel_pr_followup`. Manual `followup_count` keeps report identities unique.

- [x] Test specialized buttons and normalization before implementation.
- [x] Route known report roots before initial task intake; reuse generation and audio handling.
- [x] Verify PR and checkpoint eligibility before generation and again after confirmation.
- [x] Atomically queue the existing run and mark the approved draft handled; no Linear mutation.
- [ ] Test author isolation, text/audio, duplicates, changed PRs, revocation and busy runs.

### Task 3: Verification and handoff

**Files:** operations/evaluation docs and this execution ledger.

- [x] Update rollout/testing instructions and mention the non-backfilled report limitation.
- [ ] Run `npm run check && npm test`, `mix test`, offline checks, format and diff checks.
- [ ] One fresh read-only whole-change reviewer; fix consequential findings with regressions.

## Execution ledger

- Base: `372e44f421b5ff18e3ffcbb0266eceaad22d5de7`.
- Ruling: user explicitly requested plan then immediate implementation; no approval
  handoff pause or new workspace is introduced in this established feature checkout.
- Ruling: keep confirmation before editing; this preserves existing authorization
  semantics and costs an extra click. No publishing/deployment/commits are performed.
- Pre-flight: Task 1 defines thread identity consumed by Task 2; Task 2's counter
  changes Task 1's outbox uniqueness. Target fields reuse existing draft state and
  revision fences. Connector continuation contract is already compatible.
- Tasks 1–2 implementation complete. Receipt, action rendering, eligibility and
  bounded context tests observed RED→GREEN. Offline suite 97/97 passed. Integration
  fixtures cover report roots, text/audio approvals, duplicate events, stale buttons,
  closed/changed PRs and revoked bindings; they compile without starting the app.
- Full `mix test` attempted: blocked by localhost:5433 `:eperm`, not a green SQL run.
- Ruling: ignore unknown thread replies instead of treating them as new tasks —
  prevents old/unmapped reports becoming duplicate Linear issues — new tasks must
  start with a top-level mention; old report roots are not backfilled.
- Ruling: retain mappings for all acknowledged report roots, while preferring the
  oldest for future replies — concurrent outbox delivery cannot leave a second
  visible root unrecognized — rare concurrent first reports can appear separately.
- Review pending; no package, live provider configuration or deployment changes.
- Final review: one fresh read-only reviewer found no concrete production defects.
  Regraded its test sequencing finding as consequential (it would fail the full
  suite): closed-PR error notification is delivered by the terminal-message tick,
  so the integration test explicitly performs that tick before asserting the reply.
- Final: Ruling: SQL concurrency/migrations and live Slack/connector execution remain
  unverified here — full `mix test` and the designated provider smoke test are
  required before rollout — compilation/offline fixtures are not runtime proof.
- Final: Ruling: retain existing connector PR/head verification at publication —
  provider state can change after observation — stale work must block, never force-push.
- Final: Ruling: concurrent first report roots remain permitted as documented —
  all acknowledged roots are mapped — a rare concurrent first delivery can produce
  separate channel messages, both safe to reply to.
- Final verification: connector typecheck and suite 114/114; platform offline97/97;
  SQL integration module compiles. Full database suite is blocked by `:eperm`.
  Final review test fix is source-checked/compiled, not claimed SQL RED→GREEN.
- No deferred minors. No commits, pushes, npm releases, deployments or live provider
  calls were performed. Connector source and version remain unchanged.
