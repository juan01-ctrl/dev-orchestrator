# Pre-release Evals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. Track steps with checkboxes.

**Goal:** Build fail-closed regression evals and run a bounded reliability cycle.
**Architecture:** Native test reporters feed a dependency-free Node runner; an
independent corpus measures actual intake outputs separately; live evidence is explicit.
**Tech Stack:** Node built-ins, existing Elixir/ExUnit/Jason/OpenAI adapter, GitHub CI.
**Spec:** `docs/superpowers/specs/2026-10-26-release-evals-design.md`

## Global constraints

No unrelated production behavior/model/credential changes, automatic commit,
deployment or merge. Preserve unrelated edits. No live provider calls by default. Reports must
not contain raw subprocess output or secret material. Incomplete checks never pass.

## Review focus

- A renamed/skipped test must fail coverage rather than disappear from the denominator.
- A process timeout/crash or malformed reporter data must make the run fail.
- Repeating identical tests does not prove model/provider reliability.
- A required literal in a disclaimer must not satisfy an actionable-field criterion.
- Missing live evidence must not be represented as a successful deployed cycle.

### Task 1: Native regression runner

**Files:** `evals/{run,core,node-reporter}.mjs`, `evals/manifest.json`,
`evals/test/core.test.mjs`, `platform/test/support/eval_formatter.ex`.
**Interfaces:** `assess(manifest, records, exitCode)` returns fail-closed case results.

- [x] Write tests for pass/fail/missing/skipped/duplicate results and invalid manifests.
- [x] Observe RED, implement bounded subprocess runner/reporters, observe GREEN.
- [x] Map existing deep state/recovery tests to named categories; run three seeds.

### Task 2: Model-behavior corpus and graders

**Files:** `evals/{intake-cases.json,grade.mjs,intake.exs}`, grader tests.
**Interfaces:** `gradeDraft(case, draft)` returns named checks without raw input/output.

- [x] Write negative controls for missing/contradicted requirements and wrong-field matches.
- [x] Observe RED; implement independent field-specific graders and versioned corpus.
- [x] Add explicit opt-in existing-adapter execution, per-call timeout and bounded trials.

### Task 3: Release gate and reliability cycle

**Files:** `.github/workflows/ci.yml`, `docs/evaluation.md`, cycle evidence report.

- [x] Wire deterministic evals into CI with sanitized artifacts.
- [x] Run native suites/typecheck, eval runner and grading negative controls.
- [x] Attempt authorized deployed flow; grade visible/persisted outcomes honestly.
- [x] One fresh whole-change review; fix consequential findings with regressions.

## Execution ledger

- Ruling: user selected pre-release evals and explicitly requested implementation;
  proceed without another approval pause, using existing languages/frameworks.
- Ruling: work in the established feature checkout, preserving unrelated edits,
  consistent with the user's existing in-place workflow; no new worktree requested.
- Ruling: no automatic commits or deploys; user historically publishes manually.
- Pre-flight: Task 1 owns reporter schema consumed by Task 3; Task 2 remains a
  separately labeled model-behavior gate and cannot inflate deterministic coverage.
- Live preflight: existing authenticated page confirms the requested test email and
  one project. Render navigation showed a cold-start interstitial. Slack initially
  showed a reconnect warning. No credentials or permissions changed.
- Tasks 1–2: harness and grader functions observed failing before implementation;
  ten self-tests now pass, including positive/negative controls for all ten corpus
  cases. Native reporter trial proved 200 platform and 114 connector test records
  and all 31 required scenario selectors. Three-seed run passed all scenarios.
- Model probe: explicit opt-in adapter invocation correctly exited nonzero with
  blocked_configuration; no local OpenAI key is available. Do not extract a remote
  deployment secret or alter credentials to force this gate green.
- Ruling: add an independent PR postcondition grader — live success prose is not
  sufficient evidence — bounded to the exact one-file smoke task, not general code
  correctness. Negative controls reject wrong PR/branch/head/content/additional files.
- Live: Render eventually returned HTTP 200 readiness. Authenticated project page
  confirms one test repository, connected Slack/Linear/GitHub and #all-agents.
  Valid Slack web mention produced a faithful proposal; a scoped v2 correction
  was submitted before confirmation. Earlier native-app UI trials sent one empty
  mention and one plain-text @Test message; they are not counted as intake trials.
- Task 3 live finding: JUA-44 produced PR #17 on the expected branch with exactly
  the requested v2 file bytes, independently fetched at head 126c3ff531479dd489747a2c928fc73f40208195.
  Approved v3 follow-up was then cancelled by Linear lifecycle deactivation because
  delivery moved its original issue to In Review. No second PR or issue was created.
- Ruling: include the minimal local lifecycle fix — preserve verified explicit
  workflow-v2 PR continuations only in the configured review state and same Linear
  team/project — otherwise a green gate would retain the live regression. Other
  inactive states, removal and scope changes continue to cancel. Cost if wrong:
  review reconciliation could incorrectly preserve work; dedicated negative tests
  retain these cancellation fences. The fix is not deployed or live-verified.
- The exact live failure reproduced RED in LinearReviewContinuationTest (cancelled
  instead of unchanged); the minimal guard made all three new SQL tests GREEN.
  These three scenarios join the required manifest (now forty).
- Fresh read-only review found two consequential grader weaknesses: same-field
  negated/contradicted requirements and substring false positives. Five concrete
  counterexamples observed RED, then GREEN with explicit contradiction rules,
  literal/numeric boundaries and newline preservation. No deferred minors.
- Final review boundaries: live providers and hosted CI were not reviewed; parent
  independently exercised live text/corrections/publication, while audio remains
  blocked by Chrome file-upload permission. General semantic/visual/code quality
  is outside the narrow grader. Existing unrelated edits remain untouched. The
  lifecycle fix was discovered after the single reviewer pass and is covered by
  new SQL regressions plus author review, not claimed independently reviewed.
- Final verification: required scenarios 40/40 across all three seeds; each trial
  passed all 203 platform and 114 connector tests. Eighteen harness/grader checks
  passed, connector typecheck/build passed, offline 97/97, format and diff checks
  passed. Sanitized regression artifact:
  `.runtime/evals/2026-10-26T14-54-31-893Z/regression.json`.
- Live cycle is FAILED, not green: independent delivery grader passed the original
  v2 PR and failed the v3 follow-up on exact bytes/new commit. Evidence retained in
  `.runtime/evals/2026-10-26-live-cycle/`, public-safe narrative in
  `docs/evaluation-cycles/2026-10-26.md`. Audio is permission-blocked, model corpus
  configuration-blocked. No deployment, merge or credential/permission change.
- Ruling: preserve the live test issue/PR and cancelled run for inspection; no
  automatic retry or cleanup of material artifacts. Only the connector process
  started by this session was gracefully stopped, returning to the prior state.
- Ruling: retain the observed actor-confusing publication summary as a documented
  rollout concern, not a broad prose-rewriting change in the eval implementation.
  The actual provider state is the grader's authority. Cost if wrong: users may
  misread the summary despite the correct verified PR link.
- Final: no deferred reviewer minors. Existing unrelated edits remain preserved;
  source changes are left uncommitted for the user's normal publication workflow.
