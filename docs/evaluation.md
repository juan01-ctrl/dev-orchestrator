# Evaluation acceptance checklist

This is a checklist to execute, not a claim that these checks have already passed.

## Automated pre-release regression gate

From the repository root, with the existing local test PostgreSQL running:

```bash
node evals/run.mjs --trials 3
```

This runs the eval harness's own tests, connector typecheck/build and the complete
platform/connector suites three times. `evals/manifest.json` identifies 83 required
workflow scenarios across intake, authorization, idempotency, validation,
continuation, publication and recovery. Renamed/missing/skipped/duplicate scenarios,
any failing native test, malformed evidence, process failure or timeout fail the
gate. These are deterministic state/contract evals, not claims about live models.
ExUnit seeds vary; connector repetitions exercise repeated runs but are not seeded
model trials. Every attempt is required to pass; there is no best-of-N selection.

The new `release-evals` CI job runs this command without external provider access
and uploads only sanitized `regression.json` artifacts, including failures. Make
that job a required branch check through normal repository administration before
relying on it to prevent merges; this source change does not alter branch rules.

Reports live in ignored `.runtime/evals/<timestamp>/`, with revision, dirty flag,
manifest hash, seeds, durations and per-scenario evidence. They deliberately set
`release_ready: false`: deployed/model validation is a separate requirement.
No raw subprocess logs, credentials, prompts or model responses are saved.

### Actual intake-model evaluation (explicit opt-in)

`evals/intake-cases.json` contains ten fixed English/Spanish requests, transcript
fixtures, revisions, PR follow-ups, missing-context cases and adversarial quoted
input. Hand-authored positive and negative controls test the field-specific
graders before trusting their scores. A requirement found only in background
context cannot satisfy a scope/acceptance check. This narrow benchmark catches
literal omissions, wrong values and selected scope expansion; it does not prove
general semantic correctness, actual audio decoding, visual fidelity or code quality.
Known same-field negations, contradictory publication actions, wrong literal/numeric
boundaries and omitted newlines have explicit rejection controls. Unrecognized
paraphrases or subtle contradictions still need human review; these rules are not
a calibrated general-purpose semantic evaluator.

With the existing OpenAI configuration available in the current environment:

```bash
node evals/intake.mjs --live --trials 3
```

This uses the production `OpenAI.structure_task/1` adapter and draft normalization,
without starting the application, database workers or executor. It uses the
configured `OPENAI_TASK_MODEL` (existing default otherwise), never changes a model
or writes a key, caps the corpus at twenty cases and trials at three, allows at most
45 seconds per case, and makes no Slack/Linear/GitHub mutations. For a narrow probe,
add `--case text.exact_file`. `--live` is mandatory. Missing credentials exit
nonzero and produce blocked results rather than fake model passes.

`intake.json` records the model, corpus hash, grading checks and trial outcomes,
not raw outputs. A green result still requires periodic human inspection of model
behavior outside this deliberately small literal-fact rubric. Cost/token usage is
not reported because the current production adapter does not return that metadata;
do not infer it from elapsed time. Provider and grading failures are not success.

### Focused deployed reliability cycle

Use the explicitly authorized test account/project. Verify current deployment and
executor, then exercise a marked text request, correction, confirmation, exact
file result, and follow-up on that same PR. Test audio separately using a known
short recording with a hand-checked transcript. Verify issue/PR counts and content,
not merely the bot's success message. Leave PRs open, never merge/deploy test changes.
`evals/delivery.mjs` grades the provider snapshot's repository, PR number, branch,
base, open/unmerged state, exact head-pinned file bytes and sole changed filename.
A continuation must also advance the previously observed head. Supply snapshots
from authenticated GitHub reads; the pure grader cannot authenticate evidence.
Record artifact links, observed outcomes and blocked/not-run steps in a cycle report.
Do not interrupt a customer's active executor to simulate failure; use the local
recovery fixtures for disconnects/replays/revocation unless disruption is separately
approved. A cached browser page or a Render deploy marked live does not establish
current endpoint health. Missing live evidence keeps the release gate incomplete.

## Before connecting real tools

Independent review requires a fresh task claimed by connector 0.4.1 after the
server upgrade. Verify an independent read-only/no-network process and clean
head-pinned clone, no implementation history or publish token, rejection of
important findings, and richer human PR context. A legacy snapshot's description
must say review was not performed. Existing-PR updates must add a commit-marked
summary without overwriting human edits or duplicating ambiguous sends.

- Run connector tests and TypeScript checking with the committed package lock.
- Verify dependencies with the committed `platform/mix.lock`, run migrations and the complete `mix test`.
- Register two accounts, verify email, and prove neither can open the other's IDs.
- Exercise login, logout, password reset and the authenticated LiveView routes.
- Check the UI at 320px, 768px, 1024px and 1440px, including keyboard navigation.
- Check pairing-code expiry/replay, executor revocation and local root restrictions.
- Verify model routing and exact-host network amendments with a disposable task;
  confirm unknown hosts and permission expansions are denied.
- Set `DEV_ORCHESTRATOR_SLOTS=2`, submit two eligible tasks, and verify isolated
  worktrees/journals and project concurrency backpressure.
- Interrupt networking mid-task; confirm preserved files and reconciliation without
  an automatically duplicated task or PR.
- Restart the connector with an active journal; confirm the same Codex thread and
  worktree resume, and that a live lock is never removed.
- Trigger missing context; verify exactly one Slack link, owner-only UI response,
  answer delivery to the same Codex turn, expiration, and a blocked outcome when no
  answer arrives.
- Inspect `/api/v1/ready` with no executor, configured providers, queued work and
  delivery incidents; confirm it distinguishes optional/degraded components without
  returning tenant IDs, counts, tokens or provider error bodies.

## Authorized provider smoke test

Use a dedicated test repository and Slack channel. Do not use a production task
or the old Symphony checkout. Register and configure the operator's provider apps,
connect them from a project, invite the Slack bot, and authorize a local executor.

1. Queue a task to create `prueba.txt` containing `esto es una prueba`.
2. Confirm execution occurs in an isolated checkout, on `task/<run-id>`.
3. Confirm the branch is committed/pushed without interactive approval or force push.
4. Confirm the open PR targets the configured base and its head matches the commit.
5. Confirm the web run is successful and the Slack report includes that verified URL.
6. Confirm the Linear issue enters the configured review state only after verification.
7. Replay the webhook and final event: neither should create a second run/report.
8. Trigger three equivalent controlled errors; confirm cancellation and one report,
   preserved work, and no automatic fourth attempt after server restart.
9. Disconnect the executor and revoke a connection; verify truthful actionable states.

### Slack text and audio task intake

Run only after an owner authorizes Slack reconnection and OpenAI API use for the
designated test project. Use a non-production channel and Linear project.

1. Mention the bot with one short Spanish audio file and optional text; verify the
   bot replies in the same thread and produces no Linear issue yet.
   Repeat with a text-only mention; verify the same review flow without file
   downloads or a transcription request.
2. Review the title, context, objective, scope, acceptance criteria, and open
   questions; verify the complete proposed fields are visible and the raw
   transcript is not appended to the eventual Linear issue.
3. Click from a different Slack user and verify the action is rejected without
   creating an issue or changing the draft.
4. Confirm as the original requester; verify one issue in the configured Linear
   team/project and the configured active state.
5. Verify the existing signed Linear webhook creates exactly one run and the
   existing connector flow begins. Replay the event and button interaction.
6. Try an empty mention without attachments, multiple files, an unsupported file,
   and an expired draft;
   verify safe thread responses and no unexpected Linear mutation.

Slack app reinstallation, provider calls, Render secret changes, and deployment
are owner-authorized operations and are not part of source implementation.

### Delivered PR follow-ups

1. Complete a workflow-v2 task and verify its new Slack report includes follow-up guidance.
2. Mention the bot in that report's thread with a text adjustment. Verify it proposes
   only that adjustment and does not create another Linear issue or execute before approval.
3. Revise the proposal using audio, then text; confirm pending audio is retained and
   the old button cannot apply it. A different requester must not confirm the draft.
4. Approve it and verify the same executor/conversation, task branch, and PR are
   reused, checks run, and the final report replies in the original report thread.
5. Request a second adjustment; replay the first event/button and confirm no duplicate
   continuation or new Linear issue. Verify the original Linear issue stays linked.
6. Close/merge the PR, change its head, revoke/unbind the executor or advance the run's
   lifecycle between proposal and approval. Verify a clear refusal and no overwrite,
   new branch, replacement PR, or silently renewed proposal.
7. An unknown or pre-migration report thread must not create a new Linear task.

## Publication

Do not publish as a completed product until the deployment gates above pass.
The user's authorized destination is `juan01-ctrl/dev-orchestrator` on `main`.
Check remote history first, never force-push, and verify the remote commit after push.
