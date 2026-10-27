# Autonomous Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. Steps use checkboxes.

**Goal:** Fix false cancellations and validation blocks; autonomously repair reviewed
work and ask only important binary decisions through secure Slack buttons.
**Architecture:** Extend reconciliation, frozen validation contracts, connector review
recovery and durable clarification delivery; preserve exact-head publication fences.
**Tech Stack:** Existing TypeScript/Node, Elixir/Phoenix/Postgres, Slack Block Kit.
**Spec:** `docs/superpowers/specs/2026-10-26-autonomous-recovery-design.md`

## Global constraints

No global settings, credential/model/permission changes, live provider writes,
commits or release actions. Preserve unrelated October 23 documents and running tasks.
Base: `cf6c08e4d8937ec05482de2494a5ddbed1f18e03`.

## Review focus

- A transient provider omission must not cancel or duplicate an executing task.
- Additive scripts must not hide edits to an original command or weaker validation.
- Repair/review retries must stay bounded across crashes, pauses and continuations.
- Slack callbacks must prove identity, current destination and exact question binding.
- Approval/denial must never silently expand execution authority or approve stale work.

### Task 1: Correct reconciliation and validation contracts

Files: reconciler/lifecycle and tests; connector environment/worker and tests.
- [x] RED: bulk omission with visible direct issue; unavailable/null direct result;
  inactive/direct removal; additive test script accepted and run; changed original rejected.
- [x] Implement direct confirmation, precise cancellation reasons, additive-only plans.
- [x] GREEN: focused native tests and record results.

### Task 2: Bounded independent review recovery

Files: reviewer/worker/journal/types; reviewer/recovery tests.
- [x] RED: request-changes then approval publishes after repair; persistent defects
  stop within budget; incomplete review retries once; citations and output are strict.
- [x] Feed findings into the existing implementation thread, re-run validation and
  fresh review, persist budgets before starting work, invalidate approval after edits.
- [x] GREEN: focused suites, crash/continuation cases, exact-head publication.

### Task 3: Important Slack decisions

Files: connector decision policy; Runs/Clarification/SlackDecisions, Slack delivery,
signed webhook controller, migration and tests.
- [x] RED: routine questions stay autonomous; important requests pause; Slack buttons
  resume on approve/deny; reject wrong user/workspace/channel/message/generation,
  revoked grants, expiry and contradictory replays.
- [x] Implement typed question policy, saved bindings/receipts and shared answer logic.
- [x] GREEN: real database and signed webhook tests plus connector pause tests.

### Task 4: Release verification

Files: eval manifest, operations/evaluation docs, connector version/install commands.
- [x] Add required regression scenarios and document budgets/approval limits/migration.
- [x] Run full `mix test`, `npm test`, typecheck/build and three eval trials.
- [x] One fresh independent whole-change review; confirmed fixes RED→GREEN.

## Ledger

- Ruling: proceed inline under the user's explicit execution request and established
  feature checkout/manual release workflow. No additional approval gate for the plan.
- Ruling: two review repairs, one incomplete-review retry, three implementation turns
  total within the existing twenty minutes; this trades eventual completion for bounded cost.
- Ruling: reuse requester/OAuth-installer identity without new Slack scopes; unknown
  identity uses the existing authenticated dashboard rather than an unsafe channel vote.
- Ruling: no automatic permission expansion from Slack approval; decisions affect
  task intent only, so some requests still need a separately configured integration.
- Ruling: package.json was concurrently changed to a scoped/private package by the
  user. Preserve that unrelated edit and defer version/install-command changes to
  the manual release step; the next npm release must use an unused version.
- Task 1: focused reconciliation and continuation suite 7/7; environment and
  recovery suite 22/22 passed. Bulk omission, unknown visibility, additive scripts
  and unsafe hook additions were observed RED before their fixes.
- Task 2: review/recovery suite 23/23 passed before later decision cases. Initial
  request-changes repairs, persistent findings, invalid/inconclusive retries and
  strict findings were observed RED; budgets survive human pauses.
- Task 3: signed Slack/database tests passed for approval, denial, identity and
  destination fencing, replay, expiry, revocation, unknown identity and changed
  grants. Later-generation duplicate-answer test was RED, then GREEN after fix.
- Preliminary full verification: 211 platform and 137 connector tests passed.
  Additional boundary tests and final release verification followed below.
- Final independent review: one fresh-context read-only reviewer inspected a
  separate clone with independent Git storage and no remote. Four Important
  findings confirmed; all fixed in one pass, without another review dispatch.
- Final: fixed technical retries resetting budgets — execution-retry journal test
  RED→GREEN. Budgets reset only for explicitly new Slack/PR work, not retries.
- Final: fixed loss of saved blocking findings — saved-rejection recovery and
  interrupted-review budget tests RED→GREEN. Persist launch reservations before
  review and transfer outstanding findings into cross-generation repair context.
- Final: fixed PR-followup cancellation after human answers — real database
  approval/denial + reconciliation test RED→GREEN. Preserve approved work origin
  through both answers and technical retries, keeping all scope/head fences.
- Final: fixed explicit config omitting new tests — explicit-build plus failing
  added-test case RED→GREEN; preserve original commands and append recognized additions.
- Final safeguards: compact decision headers and structured output fallback tests
  RED→GREEN. Unresolved/malformed decision output cannot become completed work.
- Validation finding: intermittent unmapped failure identified as the existing
  claim/snapshot test. Both inserted fixtures use transaction-pinned now(), so its
  assumed FIFO order was unspecified for equal timestamps. Give the expected first
  task an explicit earlier timestamp; do not weaken its snapshot/concurrency checks.
  Sanitized eval reports now retain failing test names without assertion/log bodies.
- Offline correction: keep the new pure Event test independent of Phoenix UI code,
  which is deliberately absent from the offline harness. Offline suite 98/98 passed.
- Final verification: full platform 215/215, connector 145/145, offline 98/98;
  TypeScript typecheck/build, Elixir formatting and diff checks passed. Release eval
  report `.runtime/evals/2026-10-26T18-45-43-255Z/regression.json`: 81/81 required
  scenarios over three trials, each with all platform/connector tests passing.
- Final: Ruling: reviewer declined live provider/sandbox and semantic model-quality
  judgment; local fixtures establish configured behavior, not production delivery or
  perfect importance classification. Keep live smoke explicitly opt-in; do not claim it.
- Final: Ruling: reviewer did not run suites/migrations or inspect concurrent package
  edits. Parent ran all native/eval checks and the migration locally; pending package
  name/access settings are untouched. Production deployment remains a separate action.
- Deferred minors: none reported by the final reviewer.
