# Workflow reliability rollout

The existing Phoenix/PostgreSQL control plane and local connector remain the
execution owners. No new provider subscriptions, evaluator agents, or workflow
engine are required. Merge and deployment remain operator actions.

## Upgrade order

1. Back up PostgreSQL and the connector runtime directory. Let active tasks finish
   before stopping the old connector; do not run two processes against one runtime.
2. Run the full platform suite against an isolated PostgreSQL database. Apply the
   four additive migrations dated 2026-10-29 through 2026-11-01 using the existing
   release migration command before starting the updated web service.
3. Build and release connector 0.2.0 through the existing npm publication workflow.
   The source version change does **not** publish it. Until publication, use the
   locally built CLI (`cd connector && npm run build && node dist/cli.js run --config
   /absolute/path/to/connector.json`). Keep the same enrollment and runtime directory.
4. Restart the updated connector. Its heartbeat advertises `workflow_version: 2`.
   Old connectors can finish legacy work but cannot claim investigation tasks or
   fresh retried lifecycles. Existing snapshots retain their branch identity.
5. Smoke-test a text request, an audio request, a mentioned thread correction,
   stale confirmation, a read-only investigation, and a human pause/resume before
   enabling automatic PR repairs for any project.

## Contracts

Fresh execution lifecycles use `task-attempts/<run>/attempt-<lifecycle>` so they do
not collide with retained legacy `task/<run>` refs. Automatic retries
retain the branch and frozen project configuration. Manual retry creates a fresh
lifecycle; it never resets a previous attempt's branch.

The connector pins `.dev-orchestrator.json` commands and package script definitions
before the first model turn. Changes to those definitions require human review.
Code changes without any required checks block as `validation_failed`, with a
`not_run` validation entry; documentation-only changes may finish without code checks.
Configure non-Node projects and monorepos explicitly with argv arrays, for example:

```json
{"setup": [], "validate": [["mix", "test"]]}
```

This protects command definitions, not the semantic strength of every changed test;
human review is still required. Recovered pre-upgrade journals without a pinned
plan block rather than trusting an already modified validation configuration.

Manual tasks expose `implement` and `investigate`. Investigation uses read-only
permissions, produces a report and cannot obtain publication credentials or submit
a PR candidate. It does not install dependencies or run the implementation pipeline.

## Slack corrections

After receiving the first proposal, reply **in that thread**, mention the bot, and
provide corrected text or one audio attachment. Only the original requester can
revise that open draft. The bot produces a new numbered revision with fresh buttons;
old buttons cannot confirm it. Duplicate Slack events are ignored. Corrections after
confirmation/cancellation/expiry are ignored; send a new root request instead.
Text corrections retain a pending audio correction until generation incorporates
it. A new audio attachment replaces the previous pending audio selection.

## Slack feedback on a delivered PR

After migration `20261102000000_add_slack_pr_followups`, delivered Slack reports
record a scoped thread-to-run mapping. Reply in that report's thread, mention the
bot, and send text or one audio file. Review its proposed adjustment and click
**Apply to PR**. The original executor resumes the same conversation and updates
the existing branch/PR; no new Linear issue is created. The next execution report
returns to that thread. Connector 0.2.0 already supports this continuation; this
server-only feature does not require another npm version or Slack subscription.

For tasks originally requested through Slack, only the original requester can ask
for adjustments. Other tasks accept requests from the configured channel, as initial
intake does. Each proposal can be revised/confirmed/cancelled only by its author.
One open proposal per run is permitted. Text corrections retain pending audio; a
replacement audio attachment supersedes the prior pending selection.

Every proposal pins its delivered lifecycle and head. An approved proposal is
rejected if the PR changed/closed/merged, the task is busy, its original executor
was revoked/unbound, the connection changed, or seven days passed since delivery.
The confirmation is separate from the opt-in three-round automatic CI repair limit;
each explicit approval grants a new twenty-minute execution budget. Merge remains human.

Older reports cannot be backfilled without history access. Unknown thread replies
are ignored rather than accidentally creating a new Linear task. Start new tasks
with a top-level mention. A lost/ambiguous Slack send is retained as ambiguous, not
blindly reposted. Existing outbox diagnostics remain the recovery surface.

## Human pauses

A question stores a private conversation/workspace checkpoint under the connector's
runtime `continuations/` directory and releases execution capacity. Answer through
the run page within 24 hours. Resumption stays on the same enrolled connector,
possibly another local slot, under a new generation after a 90-second handoff window.
Only remaining active compute time is restored; waiting does not consume it.
Revocation, cancellation and expiry prevent stale execution. A missing local
checkpoint blocks explicitly instead of restarting the task without its context.
Back up this directory privately: it contains task context, not public diagnostics.

## Optional PR repairs

An owner can enable **Repair failed CI and requested PR changes** in project rules.
It defaults to off. The GitHub connection needs read access to Checks and pull
requests in addition to existing publication permissions. No permission is changed
automatically.

The observer checks five eligible runs per minute, starting 90 seconds after verified
delivery, for up to seven days after the latest delivery. It accepts current-head
failed Check Runs and current-head `CHANGES_REQUESTED` reviews from owners, members
or collaborators, including their active inline comments. Superseded approvals,
old heads, changed PR identity and duplicate feedback do not start work. Check Runs
are bounded to 100; reviews/comments are paginated to 500 each. Over-limit/provider
failures display `observation_unavailable`, rather than guessing from partial data.
Legacy commit statuses and general issue comments are not automatic repair inputs.

Repairs resume the original conversation, branch, baseline and pinned checks. Local
edits or a changed head block instead of being overwritten. Pushes are normal
fast-forwards, never force pushes. Each repair gets at most 20 minutes and there are
at most three feedback rounds per lifecycle. Delivery success still means a verified
PR, **not** CI approval or merge; PR follow-up is shown separately on the run page.
Merge is always human.
If a repair removes the entire original addition, its reversal is still pushed;
the result explicitly reports when the verified PR now has no net file changes.
Retained successful PR worktrees last seven days; ordinary
successful worktrees retain the existing one-day cleanup policy. Do not delete
private continuation checkpoints while their pauses or review windows are active.

## Verification and rollback

Run `npm run check && npm test` in `connector/`, `mix test` in `platform/`, and the
offline checks (`elixir test/offline.exs`). Offline checks do not prove SQL locking,
migrations or real provider behavior. Provider smoke tests stay opt-in.

Disable PR feedback before rollback, stop connectors cleanly, and retain the additive
schema and local checkpoints. Drain paused/new-branch attempts before reverting to
an older server/connector; old binaries do not understand workflow-v2 continuations.
