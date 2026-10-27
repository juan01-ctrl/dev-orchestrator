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

## Independent candidate review (connector 0.4.0)

Release `@juan01-ctrl/dev-orchestrator-connector@0.4.0` with its configured restricted
access. Deploy the server and its Slack decision migration before starting the new
connector. Then stop the old connector cleanly and start 0.4.0 using the existing
config and runtime directory; do not pair again or run two processes against the
same runtime. No new provider permission is needed. Source changes do not publish npm.
When changing the package name or version, update all dashboard pairing/start
commands and their LiveView expectations before running release evaluations.

The new connector advertises `review_version: 1`. Fresh implementation snapshots
claimed by that capability freeze `review_policy.version: 1`. Existing snapshots,
including old continuations, retain their original policy and must not be described
as independently reviewed. A snapshot requiring review cannot obtain a publishing
credential from an executor that no longer advertises the capability. To evaluate
this feature, use a fresh task after both upgrades.

After deterministic checks and a local trusted commit, the implementation process
stops. The connector exports only the candidate and baseline into a private clone
with its own Git objects/index, no remotes and no implementation caches or notes.
It verifies/copies task references separately. A fresh Codex process/thread reviews
the request and pinned diff under read-only filesystem/no-network permissions,
without publication credentials or implementation conversation/summary. It uses
the same immutable task model; this feature does not change model routing.
Reviewer commands ignore host Git configuration/attributes and cannot approve
permission escalation. Publication checks the reviewed SHA again inside the trusted
push operation, after any asynchronous credential acquisition.

Review v1 is inspection-only: it does not install dependencies or claim another
build, browser test or visual verification. There is no writable source/scratch
area in this initial version. Critical/important findings and incomplete/invalid
reviews block publication. Minor findings and limitations remain in the PR context.
The reviewer gets at most three minutes within the task's existing overall budget.
Review findings now feed back to the implementer for at most two repair cycles,
sharing the existing limit of three implementation/validation attempts and twenty
minutes. Each resulting candidate is validated and independently reviewed again.
The implementer must reproduce or refute claims rather than blindly changing code
to satisfy them. An invalid/incomplete review gets one fresh retry. Persistent
findings or exhausted budgets stop with preserved work. Model review can still be
wrong; human review and deterministic checks remain necessary.
Review launches reserve a persisted total allowance of four, including interruptions.
Technical retries and human answers preserve consumed budgets and unresolved findings;
only an explicitly approved new PR follow-up starts a new work budget. Paused turns
resume without being charged as another repair. Human answers and execution retries
retain the approved PR-work provenance so reconciliation does not cancel an existing
In Review follow-up. Fresh review still binds to the new execution generation.

The private journal binds approval to the original baseline, exact head, generation
and task digest. Same-head publication retries may reuse it; changed candidates
and continuations need a new review. Missing approval after a recovered publication
checkpoint runs review again, not an implementation restart. Local commits remain
available when review blocks, with private continuation evidence retained.

New PR descriptions include original intent, approved adjustment, agent rationale,
changed files, separately labeled connector-executed and agent-reported validation,
review findings/limitations, exact
commit provenance, risks and a human checklist. Agent claims are labeled; the
trusted connector publishes afterward. Original task text is redacted/escaped for
GitHub, not treated as Markdown instructions or notifications.

Each reviewed publication also adds a detailed commit-marked summary comment,
including subsequent changes to an existing PR without overwriting a human-edited
description. Comment lookup is bounded and scoped to the bot and exact commit.
A ready checkpoint resumes an unattempted send. Pending/ambiguous sends are
reconciled through read-only lookup and never blindly repeated. The comment body
and target are saved atomically with the candidate verification checkpoint. If delivery
fails, the verified PR can still succeed: its description/checkpoint is the recovery
surface and the run summary flags delivery attention. This does not roll back code
or claim that the comment was delivered.

No live sandbox/provider execution is implied by source-level fixture tests. Before
rollout, opt into a disposable real task and verify read-only enforcement, fresh
thread identity, no publishing credentials, blocking findings, and actual PR context.

## Autonomous recovery and important decisions

Deploy migration `20261103000000_bind_slack_decisions.exs` with the server and run
a connector release containing this change. The existing Docker release runs
migrations at startup. Do not republish an already-used npm version. Package naming
and visibility are separate release settings; preserve any pending scoped/private
package change when preparing the next version. Existing stopped tasks require an
explicit retry after upgrading; this change does not restart them automatically.

A missing bulk Linear result is confirmed by a direct issue lookup. An unavailable
or null direct result preserves the run and retries reconciliation; it does not
create another activation. Explicit removal and confirmed inactive states still
cancel. Messages distinguish removal, state changes and changed project scope.

Adding a test/check script is permitted if every original script, package-manager
selection and explicit validation configuration remains unchanged. Original checks
still execute, together with newly detected checks. New lifecycle hooks and changed
or removed original scripts are rejected and sent back for autonomous repair.
Old checkpoints without script details retain conservative validation behavior.

Routine agent questions are answered with autonomous guidance. Only a single
concrete binary proposal with consequences and Approve/Deny options qualifies as
an important decision. Headers identify irreversible data changes, security/privacy,
external commitments or material scope choices. The model judges importance; this
format fence is not a semantic guarantee. Technical failures use repair budgets,
not human approval. Missing indispensable evidence remains an explicit prerequisite.
The same question may be returned through the structured result's `decision` field
when interactive input is unavailable. Unresolved or malformed decisions cannot
count as completed work or reach publication. Compact Data/Security/Commitment/Scope
headers fit the input tool's short-label constraint.

Important decisions use the existing durable wait: the slot is released, the question
lasts up to 24 hours, and the answer queues a new fenced generation of the same task.
Slack buttons bind to the current connection grant/workspace/channel, original
requester or OAuth installer, exact delivered message and clarification generation.
Unknown Slack identity gets an authenticated dashboard link without unsafe buttons.
Duplicate identical clicks are harmless; later-generation, expired, revoked or
contradictory clicks cannot answer. Denial is recorded explicitly for the resumed
agent to avoid the proposed action and choose a safe alternative when possible.

Approval changes task intent only. It does not grant new network or filesystem
access, expose credentials, change model selection, override checks, or authorize
automatic publication/deployment/merge outside the existing trusted workflow.

## Verification and rollback

Run `npm run check && npm test` in `connector/`, `mix test` in `platform/`, and the
offline checks (`elixir test/offline.exs`). Offline checks do not prove SQL locking,
migrations or real provider behavior. Provider smoke tests stay opt-in.

Disable PR feedback before rollback, stop connectors cleanly, and retain the additive
schema and local checkpoints. Drain paused/new-branch attempts before reverting to
an older server/connector; old binaries do not understand workflow-v2 continuations.
