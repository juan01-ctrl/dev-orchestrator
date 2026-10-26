# Independent Reviewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. Steps use checkboxes.

**Goal:** Review pinned candidates independently and provide complete human PR context.
**Architecture:** Clean-room snapshot + dedicated Codex session; journaled review
gate before publish; trusted Markdown context and bounded idempotent update comments.
**Tech Stack:** Existing Node/TypeScript, Git, Codex app-server, Phoenix snapshots.
**Spec:** `docs/superpowers/specs/2026-10-26-isolated-reviewer-design.md`

## Global constraints

No publication/deployment/model/credential/global-config changes. Preserve old
snapshots and existing publication fences. No implementation history in reviewer
input. Read-only reviewer, no publish credential or network. Fail closed.

## Review focus

- Changed head or resumed generation must not reuse an old approval.
- Reviewer output, paths and verdicts are untrusted and must be strictly validated.
- Clone must not share implementation object stores, remotes, Git config or caches.
- Ambiguous GitHub comments must not be repeated on a publication retry.
- PR context must distinguish agent claims, deterministic checks and review limits.

### Task 1: Isolated reviewer

**Files:** `connector/src/reviewer.ts`, publisher snapshot API, app-server structured
result support as necessary, `connector/test/reviewer.test.ts`.
**Interfaces:** `reviewCandidate(input, dependencies?) -> CandidateReview`;
`Publisher.reviewSnapshot(commit, callback)` supplies an isolated pinned clone.

- [x] Add failing tests for strict findings, isolation, pinned refs and fresh context.
- [x] Implement bounded clean-room session and verified asset copying.
- [x] Verify read-only/no-network/fresh-thread policy and cleanup on failure.

### Task 2: Gate and human-facing publication

**Files:** worker/journal/types/server snapshot, report formatter, publisher/comment
integration; worker/recovery/publisher/report tests.

- [x] Add failing tests for no push before review, stale review invalidation,
  inconclusive review and retry reuse.
- [x] Add structured independent-review findings and richer PR body/update comment.
- [x] Test safe formatting, redaction, exact-head binding and ambiguous comment writes.

### Task 3: Verification and rollout

**Files:** operations/evaluation docs, required eval manifest and plan ledger.

- [x] Document server/connector upgrade and inspection-only review limits.
- [x] Run full native suites, typecheck and three-trial eval gate.
- [x] One independent whole-change review, consequential fixes RED→GREEN.

## Ledger

- Base: `6affa66`.
- Ruling: user explicitly requested implementation of the agreed independent
  reviewer; proceed inline, preserving the established checkout and manual release
  workflow. No new worktree, commit, push or provider-backed smoke run.
- Ruling: important findings and incomplete review block publication, with no
  automatic fix loop; this favors safety over task completion rate and adds up to
  three minutes within the existing deadline.
- Ruling: use the immutable selected task model for review, avoiding an unapproved
  model change. Review v1 is inspection-only; deterministic project checks remain
  the authoritative executed validations.
- Pre-flight: Task 1's pinned result feeds Task 2's journal fence and formatter.
  Task 2 opts in new snapshots; legacy publication remains backward compatible.
- Task 1: complete. Five reviewer tests cover malformed verdicts, exact identity,
  separate Git storage, fresh process/thread, missing credentials, read-only/no-network
  profile, denied command approvals, tracked-tree tampering, and cleanup. The missing
  base ref, accepted command approval and candidate tampering cases were observed
  failing before their respective fixes.
- Task 2: complete. Worker tests block publication credentials on important or
  inconclusive findings and reuse exact approval on publication retry. Publisher
  tests verify commit/bot-scoped comment deduplication and ambiguous-send handling.
  Formatter tests verify human context, truthful limitations and safe redaction.
- Task 3: complete. Native platform suite 204/204; native connector suite 128/128;
  TypeScript check/build and Elixir formatting passed. Final release eval gate
  53/53 scenarios over three trials passed. Sanitized report:
  `.runtime/evals/2026-10-26T15-52-46-739Z/regression.json`.
- Validation observation: an earlier eval trial reported one platform-suite failure
  outside the mapped scenarios. The same seed passed on immediate native and
  formatter reruns; all three subsequent eval trials passed. No source change was
  made to conceal or waive that failure.
- Final review: one fresh-context independent reviewer inspected a separate clone
  with independent Git storage and no remote, against baseline `6affa66`. Four
  Important findings were confirmed and fixed in one pass, without a re-review:
  reviewed-SHA publication race, inherited Git settings, skipped summary after a
  crash, and conflated check provenance. Regression tests for each failed first;
  the focused fix suite passed 35/35 and the final complete suites passed above.
- Final: minor (deferred): finding citations validate tracked paths and broad
  positive line bounds, but not the actual blob line count; runtime normalization
  discards unexpected fields rather than rejecting them. The requested model output
  schema already disallows extra fields. This can weaken citation precision.
- Final: Ruling: live sandbox/MCP enforcement, GitHub delivery and model quality
  require an explicitly opted-in runtime/provider smoke. Local fixtures prove
  configured isolation and recovery behavior, not those live boundaries; claiming
  live evidence would be misleading. Rollout retains this explicit acceptance step.
- Final: Ruling: keep implementation and review artifacts locally, with no commit,
  npm publication, push or deployment; the established release handoff is manual.
  This preserves reviewability but requires the user to publish connector 0.3.0
  before deploying UI instructions that refer to it.
