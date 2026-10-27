# Autonomous recovery and important Slack decisions

The user authorized implementation and tests after investigation of JUA-45/46.
Keep routine implementation, validation and review repairs autonomous. Escalate only
an indispensable high-impact human decision, with a concrete proposal and consequences.

## Selected approach

Extend the existing connector repair budget, immutable validation plan, durable
clarifications and signed Slack action endpoint. A separate workflow engine or an
unbounded self-fixing loop would duplicate these mechanisms or risk repeated work.
The implementation stays in the current feature checkout; publishing stays manual.

## Requirements

1. A missing bulk Linear result is not proof of deletion. Fetch the missing issue
   by ID; apply its current eligibility. Errors/ambiguous absence are retryable and
   preserve the execution. Explicit remove webhooks still cancel. Cancellation
   messages distinguish removal, inactive state and changed team/project scope.
2. Preserve every original package script, package manager and explicit validation
   configuration. Allow additive scripts only; select and execute added checks too.
   Never replace the original plan with a weaker current plan. Legacy plans without
   script details retain their existing fail-closed behavior.
3. A request-changes review feeds its findings back to the implementer, which must
   reproduce or refute each claim, add regression coverage and fix actual defects.
   At most two review repairs and three implementation turns total, within the same
   twenty-minute budget. Revalidate and review each resulting candidate in a fresh
   isolated session. Never reuse an old approval for another SHA. Invalid/incomplete
   reviews get at most one fresh review retry, then stop with useful evidence.
   Reserve at most four review launches durably, including interrupted launches;
   technical retries must preserve counters and saved blocking findings. Preserve
   approved PR-work provenance through human answers and execution retries.
4. Strengthen review evidence: cite actual baseline/candidate line bounds, reject
   malformed/extra structured fields, distinguish source proof from unexecuted
   runtime assumptions, and explicitly check emitted module attributes before
   making a module-loading claim. Do not add an Astro-specific production checker.
5. Implementer questions use the existing request-user-input tool. Only one concrete
   binary proposal with short header `Data`, `Security`, `Commitment`, or `Scope`,
   and Approve/Deny options is sent as
   an important decision. Routine/unstructured questions receive autonomous guidance
   instead. A structured result decision is the fallback when interactive input is
   unavailable; an unresolved decision can never count as completed work. This bounds
   format; importance is still a model judgment, not a guarantee.
6. Persist important questions using the durable pause/resume flow. Slack buttons
   bind to clarification/run/lifecycle/generation, current connection, workspace,
   channel, requester (or trusted OAuth installer), and delivered message timestamp.
   Reject other users, stale buttons, expired questions, revoked connections and
   changed destinations. Identical duplicate answers are harmless; denial is an
   explicit denial in the resumed task, never implicit approval. Unknown Slack
   identity falls back to the authenticated owner dashboard, without unsafe buttons.
7. Approval records a task decision only. It cannot expand tool/network permissions,
   change credentials/models, publish/deploy/merge or override required validation.
   Irrecoverable technical blockers remain explicit; do not ask humans to debug tests.

## Verification and rollout

Use real Git/process/database tests with provider/model boundaries doubled. Include
reconciliation omission, safe additions vs weakened scripts, review repair/refutation,
budget/recovery fencing, signed Slack actions, identity/destination/expiry/replay and
approval/denial continuation. Run native suites, types/build and three release-eval
trials. One final independent source review; fix confirmed consequential findings.
No live provider smoke, deploy, push, commit or npm publish in this implementation.
Ship a clarification-binding migration and prepare the next connector release
separately, preserving the user's concurrent package-name/visibility edits.

## Limits

Model review can still be wrong; stronger evidence and bounded repairs mitigate it.
Read-only review uses the existing Codex sandbox and independent checkout, not a VM.
An unknown or unrecoverable prerequisite does not become safe because someone clicked
Approve. Reaching the repair budget stops with findings and preserved work.
