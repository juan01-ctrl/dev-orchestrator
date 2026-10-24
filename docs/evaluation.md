# Evaluation acceptance checklist

This is a checklist to execute, not a claim that these checks have already passed.

## Before connecting real tools

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

## Publication

Do not publish as a completed product until the deployment gates above pass.
The user's authorized destination is `juan01-ctrl/dev-orchestrator` on `main`.
Check remote history first, never force-push, and verify the remote commit after push.
