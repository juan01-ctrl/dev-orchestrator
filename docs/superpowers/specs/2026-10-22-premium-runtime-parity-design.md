# Premium Runtime Parity

## Goal

Make the hosted control plane plus customer-owned local executor feel as responsive
and capable as the previous local Symphony workflow while preserving the stronger
tenant, credential, workspace, and publication boundaries of the new architecture.

The system must accept Linear work reliably, execute it through the official Codex
app-server protocol, expose useful live progress, publish a verified pull request,
and report the result to Linear and Slack without requiring a local repository clone.

## Product contract

- A customer configures GitHub, Linear, Slack, project instructions, and an executor
  once. Routine issues then run end to end without approval prompts.
- Genuine missing context becomes one durable clarification request visible in the
  product and Slack. Policy violations and unavailable prerequisites become explicit
  blockers; they are not retried indefinitely.
- Work is isolated in managed Git worktrees and can run in parallel up to the
  configured executor and project limits.
- Source code, credentials, raw command output, private reasoning, and authentication
  material are never sent to the cloud event stream.
- The cloud service remains the authority for tenant scope, leases, run lifecycle,
  repository identity, pull-request verification, and outbound notifications.
- The local executor remains the authority for filesystem access, Codex login,
  app-server lifecycle, commands, tests, and worktree state.

## Linear intake

The service exposes one public endpoint:

`POST /api/v1/webhooks/linear`

The Linear OAuth application owns that endpoint. Customers do not create per-project
webhooks and never handle an internal connection ID. The endpoint verifies the raw
request signature and timestamp, uses `Linear-Delivery` as the idempotency key,
persists a bounded event envelope, and responds before external API work begins.

An asynchronous processor resolves the organization connection, queries only the
required issue fields, applies project/team/state grants, and advances an explicit
issue lifecycle. A reconciliation worker periodically queries issues changed after a
per-connection cursor. It recovers missed webhooks, cancels active work that became
terminal, and creates a new lifecycle for rework without duplicating an active run.

Webhook delivery is the low-latency path. Reconciliation is the correctness path.

## App-server execution

Each active run owns a durable app-server session record containing the Codex thread
ID, current turn ID, last event cursor, model policy, and sanitized status. The
connector starts or resumes a thread and may execute multiple turns within the same
run until it reaches a terminal result or a genuine blocker.

The connector negotiates available permission profiles rather than assuming a local
profile name. A project snapshot selects an allowed capability policy. Routine
workspace and Git operations inside the managed worktree proceed without prompting.
Requests outside the granted policy are rejected deterministically. Requests for
missing product context are persisted and surfaced to the user instead of being
treated as protocol failures.

The first production policy supports:

- writable task workspace, `.git`, and project-scoped `.agents` content;
- read-only project instructions and required local Codex configuration;
- Git publication only through the trusted publisher;
- configurable network access with a bounded allowlist for package registries,
  documentation, and explicitly authorized project dependencies;
- no access to global credentials, arbitrary host paths, deployment credentials, or
  unrelated repositories.

## Events and live experience

The connector translates app-server notifications into a versioned, bounded event
schema. Supported public event families are phase, plan summary, agent message delta,
command summary, file-change summary, validation result, warning, token usage,
clarification, blocker, candidate, and completion.

Every event is persisted with the existing lease generation and monotonic sequence
before acknowledgement. The platform broadcasts the accepted event through Phoenix
PubSub. LiveView subscribes to the run topic and uses the database only for initial
load and reconnect recovery. Event content is sanitized locally and validated again
by the server.

## Model and effort policy

The platform derives a model policy from task class, issue labels, and an optional
validated project override:

- routine implementation and simple maintenance: the configured Luna model at low
  effort;
- planning, review, debugging, fixes, security-sensitive changes, and rework: the
  configured Sol model at high effort.

Exact model IDs are deployment configuration, not free-form user input. The executor
reports unsupported model-policy combinations as an actionable configuration blocker.

## Parallelism and recovery

One connector process owns a supervised pool of execution slots. It never starts
more work than its advertised capacity or the server-side project concurrency limit.
Each slot has an independent worktree, journal, app-server process, lease renewal,
cancellation signal, and silence timeout.

Connector restart recovers stale locks by checking the recorded PID, reconciles every
journal, resumes eligible Codex threads, and preserves unresolved worktrees. A total
deadline, command deadline, and inactivity deadline are separate configurable values.
Three equivalent terminal failures cancel the lifecycle and produce one final report.

## Delivery and operations

Successful code changes require an independently verified open pull request against
the configured base branch. A no-change result is allowed only when the agent and
trusted Git status agree. Linear review-state updates and Slack reports are durable,
idempotent outbox jobs processed concurrently with bounded retries.

Production readiness requires structured correlation IDs, metrics for queue latency,
webhook lag, lease health, app-server turns, executor capacity, publication latency,
and outbox health, plus explicit readiness checks and runbook documentation.

## Acceptance criteria

- A valid Linear issue becomes visible in the dashboard within five seconds under
  normal delivery, and a missed webhook is recovered by reconciliation.
- Replaying a webhook does not duplicate a run; moving a completed issue back to an
  active state creates exactly one new lifecycle and reuses the existing branch/PR
  when safe.
- Moving an issue to a terminal state cancels or prevents execution.
- An executor restart resumes an eligible Codex thread without duplicating commands,
  commits, pushes, PRs, or notifications.
- Routine tasks complete without approval requests. Missing context produces one
  clarification; a response resumes the same run and thread.
- At least two tasks can execute concurrently in isolated worktrees when configured.
- Live activity appears without periodic five-second UI polling and reconnecting the
  browser reconstructs the same ordered timeline.
- Dependency installation works only through the configured network policy.
- A successful run updates Linear, posts the Slack summary, and links one verified PR.
- Provider retries, duplicate callbacks, connector crashes, and stale leases remain
  idempotent and tenant-isolated.

