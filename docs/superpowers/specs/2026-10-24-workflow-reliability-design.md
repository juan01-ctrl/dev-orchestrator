# Reliable execution and conversational task revisions

## Intent

Preserve the Phoenix/PostgreSQL control plane and local Codex executor while fixing
attempt isolation, validation, ingestion, and maintenance. Extend the existing
workflow with Slack draft revisions, durable human waits, and bounded PR feedback.
This implements the recommendations accepted in the architecture review conversation.

## Constraints and decisions

- Keep one implementation owner per branch and retain tenant/grant/lease fencing.
- Existing in-flight attempts retain their original branch; fresh attempts get a
  lifecycle-specific branch. Resuming never resets a previous attempt.
- Freeze project configuration per attempt. Live access revocation still applies.
- Pin the validation plan before model execution. Changed validation configuration
  requires review; absent checks are visible rather than reported as passing.
- Support explicit `implement` and `investigate` modes; only implementation publishes.
- Apply all intake results before acknowledging receipts or advancing cursors.
- Separate supervised maintenance, intake, Slack preparation, delivery, and reconciliation.
- Slack corrections require an explicit mention, the original requester, and an open
  draft in the same workspace/channel/thread. Version confirmations and ignore stale work.
- Human questions release execution capacity. Answers create fenced continuations
  using the preserved conversation and workspace, with bounded active execution time.
- PR feedback applies only to the current head and is deduplicated. Repairs preserve
  branch ownership and are bounded; merge remains a human action.
- Keep the configured model identities and credentials. No new workflow engine,
  agent team, vector database, live integration configuration, or deployment.

## Scope sequencing

First establish safe attempts and explicit validation. Then fix durable ingestion
and supervised jobs. Add conversational revisions and resumable waits on those
foundations, followed by PR feedback. Update deployment documentation with each change.

## Acceptance

Regression tests cover preserved old worktree heads, skipped/mutated check plans,
returned intake errors, stalled jobs, stale confirmation buttons, unauthorized
corrections, restart-safe human answers, duplicate/stale PR feedback, and cancellation.
Run connector and platform suites; document any environment-blocked integration checks.
