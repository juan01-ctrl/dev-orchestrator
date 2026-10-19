# Development orchestration platform

Status: design and native execution approved; implementation candidate pending integrated validation.

## Goal

Deliver a private cloud control plane with real customer-owned local Codex
execution. Each organization owns multiple projects, rules, integration grants,
executors and task histories. The customer receives a connector, not the private
orchestrator source. The initial delivery is a private evaluation, without billing.

## Deployment boundary

This is the new `dev-orchestrator` repository. Product code belongs in `platform/`
and `connector/`. Do not edit the existing Symphony runner, source checkout,
WORKFLOW.md, model configuration, credential stores, environment or port 4000.
Use port 4100, a separate PostgreSQL database and connector-owned runtime directory.
The requested destination is `https://github.com/juan01-ctrl/dev-orchestrator.git`.
Publish verified work there after implementation; do not replace the old origin.

## Architecture and identity

Use a Phoenix/LiveView modular monolith with PostgreSQL for durable control-plane
state, plus an outbound-only local connector. There is no public remote terminal.
Users sign in with verified email/password sessions using framework authentication
mechanisms. Local email uses a development mailbox; production uses configured SMTP.
Organizations have owner/member roles and many projects. Membership is derived
server-side; guessed resource IDs must not permit cross-tenant reads, mutations,
subscriptions or executor bindings. Invitations are deferred.

Every project owns repository/base selection, Linear routing, Slack destination,
instructions, integration grants, concurrency and failure policy. Run configuration
is snapshotted at dispatch; later project edits never rewrite an active attempt.

## Integrations and providers

GitHub uses a configured GitHub App with selected-repository installation access.
Slack and Linear use OAuth with one-use session-bound state, exact callbacks,
least scopes, encrypted tokens and explicit project grants. Owner permissions are
required to manage connections. Webhooks are signature-verified and deduplicated.
Read APIs never expose tokens. Unconfigured apps appear as `Not configured`, not
fake connected accounts. Registration of third-party apps is an operator action.

Codex runs through a separate official app-server process on the customer's host
with that customer's existing login. Never upload provider login files/tokens,
attach to desktop chats, or scrape private inference endpoints. Auth failures are
actionable blockers. Available models come from provider capabilities; do not
change current user settings or claim a listed model guarantees account access.
The private prototype does not establish authorization for commercial subscription
integration. Commercial launch remains subject to provider-authorized access.
Claude and hosted executors are deferred, not simulated in the UI.

## Executor and filesystem safety

An owner issues a ten-minute single-use enrollment code. Atomic exchange returns
a random executor credential stored locally with owner-only permissions; only its
hash is stored server-side. Enrollment is rate-limited. Project binding is explicit
and revocable. The local user also approves repository identities and canonical
workspace roots; a cloud assignment cannot broaden that allowlist.

Isolated task checkouts enable parallel work. Reject traversal, escaping symlinks,
unapproved repositories and the existing source checkout as an execution directory.
The local connector chooses the executable and sandbox; project Git metadata is
writable, global skills/configuration are not. Unsupported sandbox enforcement
blocks execution rather than falling back to unrestricted access.

Use the existing trusted-host Git publishing pattern without copying agent Git
configuration or hooks into the trusted execution context. Never force-push,
merge or deploy automatically. The cloud verifies PR repository, head branch,
base and commit through GitHub before reporting successful delivery.

## Scheduling and recovery

PostgreSQL owns task state and dispatch concurrency. States: queued, leased,
running, waiting_for_executor, blocked, succeeded, failed, cancelled. A verified
review PR is successful delivery regardless of Linear's review-state name.
No-change completion is distinct from PR-ready.

Leases have fencing generations; events carry monotonic sequence numbers.
Duplicate delivery must be idempotent; stale executors cannot change results.
Linear source IDs are unique per project. The connector journals leases and final
results before acknowledging them. On renewal failure it stops the agent before
lease expiry and preserves files. Expired active work is held for reconciliation,
not reassigned blindly; reconnect reconciles generation, journal, branch and PR.

Three equivalent failures per task lifecycle cancel automatic execution and enqueue
one failure report. Persist fingerprints/counts without secrets. Capacity waits
and expected search misses do not count. Explicit authorized retry creates an
audited new lifecycle. Routine work does not ask for approval; missing context,
credentials and denied permissions are real blockers. Production/destructive
administration is outside the automatic feature set.

## UI, reporting and operation

Provide Projects, Connections, Executors and Runs screens. Show real empty,
unconfigured, offline and blocked states. Run details expose sanitized events,
retry budget, status and verified PR link. Take inspiration from Viktor's simple
onboarding and Slack delivery, not its marketing claims or internal architecture.

Use a transactional outbox for final/blocker Slack messages, deduplicated by task
lifecycle. Delivery failure must not rerun development work. Retry explicit provider
rejections within a bounded budget; do not blindly resend ambiguous deliveries.

Ship migrations, Docker deployment, health/readiness checks and variable-only
configuration examples. Production rejects missing secrets and insecure public
configuration. Do not actually deploy or register external apps in this delivery.
Do not claim source stays entirely local: provider inference and authorized result
metadata can transmit code. Limit event payload sizes and avoid raw transcripts.

## Acceptance

- Two users cannot access each other's resources even with known IDs.
- A paired connector proves authenticated health and runs a real local Codex task.
- Task branches, commits and PRs are verified before success and Slack reporting.
- Enrollment replay/expiry, revocation, concurrency, fencing, reconnect recovery,
  webhook deduplication and third-equivalent-failure cancellation have tests.
- Restarts preserve accounts, projects, connections, task budgets and delivery state.
- Integration fixtures are never presented as live provider connections.
- The old Symphony installation and its remote/configuration remain untouched.
- External PR/Slack smoke tests require a designated authorized repository/channel.

Billing, Claude, hosted execution, invitations, general chat, cross-project memory
and a marketplace are outside this release.

## References

- https://viktor.com/
- https://learn.chatgpt.com/docs/app-server
- https://developers.openai.com/siwc/request-client-id
- Existing reference implementation: `/Users/juanierace/Documents/symphony/elixir`.
