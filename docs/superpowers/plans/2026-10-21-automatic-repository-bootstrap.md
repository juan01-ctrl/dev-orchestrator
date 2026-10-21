# Automatic Repository Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a paired local executor fetch an authorized repository, run Codex in an isolated task worktree, and publish a verified PR without a pre-existing checkout or local `gh` setup.

**Architecture:** The control plane issues lease-bound GitHub App installation tokens scoped to one repository and one purpose. The connector stores a bare repository cache under its managed data directory, creates one isolated worktree per run, and holds each short-lived token only in memory while trusted GitHub operations run outside the Codex process. The existing cloud PR verification remains authoritative.

**Tech Stack:** Elixir/Phoenix, PostgreSQL via the existing `Store`, GitHub App REST API, Node.js 22 TypeScript connector, Codex app-server/CLI, ExUnit and Node's built-in test runner.

**Spec:** `docs/superpowers/specs/2026-10-21-automatic-repository-bootstrap-design.md`

## Global Constraints

- No task requires a pre-existing local checkout or per-project `allow` command.
- The server validates executor, project binding, live lease, installation, and exact repository before issuing a token.
- Checkout tokens are scoped to `contents:read`; publish tokens are scoped to `contents:write` and `pull_requests:write`, for exactly one repository.
- Never include a GitHub token in a lease, journal, Git remote, Codex prompt/environment, event, log, or error string.
- Codex runs only in the isolated task worktree under the existing project sandbox; publication runs after the Codex process exits.
- Keep existing lease fencing, event sequencing, cancellation, journal reconciliation, task branch naming, and server-side PR verification.
- Preserve all unrelated local changes; stage and commit only files belonging to each completed plan task.
- Run `cd platform && mix test` and `cd connector && npm test` before completion; report infrastructure-blocked checks explicitly.

## Review Focus

- Expired or revoked lease, revoked executor, missing project binding, or changed project repository must not receive a GitHub token; pin these in Task 1's lease-token tests.
- An installation token must not exceed the requested repository or permissions; pin the exact GitHub API request body and returned token metadata in Task 1's provider tests.
- A malicious/stale workspace marker, worktree pointer, repository name, branch, or task lifecycle must not escape the managed root or reuse another task's checkout; pin in Task 2's workspace tests.
- GitHub credentials must not survive in config, remote URLs, journal, errors, or Codex child environment, including on command failure; pin in Tasks 2 and 3.
- Duplicate/retried publication must reuse or verify the exact PR and must not force-push, merge, or accept a PR for another head/base/commit; pin in Task 3 and retain Task 5's delivery verification tests.

---

### Task 1: Issue narrowly scoped GitHub App credentials for a live executor lease

**Files:**
- Modify: `platform/lib/dev_orchestrator/connections/github.ex`
- Modify: `platform/lib/dev_orchestrator/runs.ex`
- Modify: `platform/lib/dev_orchestrator_web/controllers/executor_controller.ex`
- Modify: `platform/lib/dev_orchestrator_web/router.ex`
- Test: `platform/test/dev_orchestrator/provider_test.exs`
- Test: `platform/test/dev_orchestrator/runs_test.exs`
- Test: `platform/test/dev_orchestrator_web/controllers/executor_controller_test.exs` (create if no executor controller test exists)

**Interfaces:**
- Add `GitHub.installation_token(installation_id, repository, purpose) :: {:ok, %{token: binary, expires_at: binary}} | {:error, atom}`. `purpose` is `:checkout` or `:publish`; it sends the exact repository and purpose-specific permissions to GitHub's installation-token endpoint.
- Add `Runs.github_token(executor, lease, purpose) :: {:ok, %{token: binary, expires_at: binary, author_name: binary, author_email: binary}} | {:error, atom}`. It validates the active lease via the existing `leased_run!/2`, reads the verified installation only when its repository matches the run snapshot, and requests the token.
- Add authenticated `POST /api/v1/executor/github-token` with JSON `{ "lease": <lease>, "purpose": "checkout" | "publish" }`. Success is `{ "data": { "token", "expires_at", "author_name", "author_email" } }`; errors expose only stable error codes.
- Use the configured GitHub App bot as commit author: name `<app_slug>[bot]`, email `<app_id>+<app_slug>[bot]@users.noreply.github.com`.

- [ ] **Step 1: Write failing provider tests** for exact-repository checkout token (`contents: read`), publish token (`contents: write`, `pull_requests: write`), and provider rejection without exposing response bodies or token material.
- [ ] **Step 2: Run `cd platform && mix test test/dev_orchestrator/provider_test.exs`** and confirm the new tests fail because purpose-scoped token generation is absent.
- [ ] **Step 3: Implement `GitHub.installation_token/3`** by POSTing to `/app/installations/:id/access_tokens` with `repositories: [repository]` and the exact purpose permissions. Return only token and expiry; do not change installation-verification token behavior.
- [ ] **Step 4: Run the provider tests** and confirm they pass.
- [ ] **Step 5: Write failing `Runs.github_token/3` tests** for live matching lease, expired lease, stale generation, revoked executor, missing executor binding, absent installation, and project repository changed after the lease snapshot.
- [ ] **Step 6: Run `cd platform && mix test test/dev_orchestrator/runs_test.exs`** and confirm the new authorization cases fail before implementation.
- [ ] **Step 7: Implement the lease-bound token operation**. Use the lease snapshot repository, re-check it against the current project and verified installation, and never record the token in a run, event, or outbox row.
- [ ] **Step 8: Add the controller route and tests** for unauthenticated requests, invalid purpose, correct executor lease, and sanitized provider errors. Require the existing executor bearer token.
- [ ] **Step 9: Run provider, runs, and controller tests** and confirm all pass.

### Task 2: Replace local mappings with managed repository cache and task worktrees

**Files:**
- Modify: `connector/src/types.ts`
- Modify: `connector/src/config.ts`
- Modify: `connector/src/cli.ts`
- Create: `connector/src/repository.ts`
- Modify: `connector/src/workspace.ts`
- Modify: `connector/src/worker.ts`
- Modify: `connector/src/journal.ts` only if workspace recovery metadata needs a validated path/marker
- Test: `connector/test/config.test.ts`
- Test: `connector/test/workspace.test.ts`
- Test: `connector/test/worker.test.ts`

**Interfaces:**
- Add `TokenPurpose = "checkout" | "publish"` and `GitHubCredential = { token: string; expires_at: string; author_name: string; author_email: string }` to connector types. Never place `GitHubCredential` in `JournalState`.
- Add `RepositoryWorkspace.prepare(root, lease, credential) :: Promise<{ path: string; branch: string; baseline: string }>` in `connector/src/repository.ts`. It validates the lease snapshot, updates the managed bare cache using the checkout token, creates/reuses only the matching lifecycle worktree, and configures the returned author identity.
- Resolve managed data root from the connector config directory: `<config-dir>/repositories/<project-id>` for bare caches and `<config-dir>/workspaces/<run-id>-<lifecycle>` for worktrees. Create directories owner-only and reject symlinked roots or markers.
- Support config versions 1 and 2; new pairing writes version 2 without `mappings`. Loading v1 ignores stale mappings and emits a migration notice. `allow` returns a clear message that project binding is managed in the web app.
- Use a fixed cleanup policy for the first release: acknowledged successful worktrees may be removed after 24 hours; failed/blocked worktrees are retained for 7 days. Never remove a workspace referenced by an active journal or live lease. The bare repository cache is retained until explicit connector data cleanup.

- [ ] **Step 1: Write failing config tests** for fresh version-2 pair config, reading v1 config with empty or populated mappings, and rejecting unsafe config files as before.
- [ ] **Step 2: Run `cd connector && node --experimental-strip-types --test test/config.test.ts`** and confirm the new migration/config cases fail.
- [ ] **Step 3: Implement v1/v2 config loading and v2 pairing** without project source paths or mappings; update CLI help and make `allow` print the web-app migration guidance.
- [ ] **Step 4: Run the config tests** and confirm they pass.
- [ ] **Step 5: Write failing repository/worktree tests** using a local bare Git fixture for initial fetch, second-run cache reuse, isolated worktrees/branches for two run IDs, idempotent retry of the same lifecycle, rejection of mismatched repository/base/lifecycle/markers, and app identity configuration without global Git identity.
- [ ] **Step 6: Run `cd connector && node --experimental-strip-types --test test/workspace.test.ts`** and confirm the new repository-bootstrap tests fail.
- [ ] **Step 7: Implement managed bare cache and worktree preparation** in `repository.ts`; keep Git remote URLs credential-free, disable hooks, validate canonical paths and Git metadata, and resolve worktree `.git` indirection safely when writing project instructions.
- [ ] **Step 8: Update `worker.execute`** to emit an initial safe progress event immediately after accepting a lease, request checkout credentials from `/executor/github-token`, prepare the worktree without any mapping/source path, and avoid saving the credential in the journal.
- [ ] **Step 9: Update `worker.test.ts`** to prove a lease with repository/base snapshot runs when config contains no mappings, that token strings never enter the journal/events/prompt, and that a credential is not passed to the Codex process environment.
- [ ] **Step 10: Run config, workspace, and worker tests** and confirm they pass.

### Task 3: Publish branches and PRs with scoped GitHub App credentials

**Files:**
- Modify: `connector/src/publisher.ts`
- Modify: `connector/src/worker.ts`
- Modify: `connector/src/api.ts` only if a narrowly typed credential request helper is needed
- Test: `connector/test/publisher.test.ts`
- Test: `connector/test/worker.test.ts`

**Interfaces:**
- Change `Publisher.publish(title, body, credentialProvider, signal)` so it requests a publish credential only after Codex exits and local commit validation passes.
- Remove runtime `gh` dependency. Push only the validated task ref using a temporary owner-only credential helper that is deleted in `finally`; keep the configured remote URL clean.
- Create/find the PR through GitHub REST API using the scoped credential, then validate exact repository, head branch, base branch, and commit before returning candidate metadata.

- [ ] **Step 1: Add failing publisher tests** for publish credential request timing, push without `gh`, REST PR create/lookup, already-existing matching PR, wrong head/base/commit rejection, and token absence from remote config/temp-file cleanup on success and failure.
- [ ] **Step 2: Run `cd connector && node --experimental-strip-types --test test/publisher.test.ts`** and confirm these tests fail against the current `gh`-based publisher.
- [ ] **Step 3: Implement tokenized Git push and GitHub REST PR operations**. Use a test-injectable command/fetch boundary; never add the token to CLI arguments, persistent Git config, stdout/stderr, or thrown errors.
- [ ] **Step 4: Update the worker** to obtain the publish token only after stopping Codex, then pass it to `Publisher`; keep candidate emission unchanged and rely on cloud verification.
- [ ] **Step 5: Run publisher and worker tests** and confirm they pass without installing or invoking `gh`.

### Task 4: Make repository setup and pre-Codex failures clear in the dashboard

**Files:**
- Modify: `platform/lib/dev_orchestrator/runs/event.ex`
- Modify: `platform/lib/dev_orchestrator_web/live/dashboard_components.ex`
- Modify: `platform/lib/dev_orchestrator_web/live/dashboard_live.ex` only for existing executor/project binding status presentation
- Modify: `platform/test/dev_orchestrator/event_test.exs`
- Modify: `platform/test/dev_orchestrator_web/live/project_live_test.exs`
- Modify: `docs/connections.md`
- Modify: `docs/protocol.md`
- Modify: `docs/security.md`
- Modify: `README.md` if it contains connector pairing/allow instructions

**Interfaces:**
- Add bounded failure categories `github_installation_required`, `github_permission_denied`, `base_branch_missing`, `github_unavailable`, and `workspace_setup_failed`; preserve existing sanitized event shape.
- Add safe progress stages `repository_preparing`, `workspace_ready`, `publishing`, and `pr_verifying` where appropriate; never accept raw output or arbitrary stage strings.
- Map each safe failure category to an actionable dashboard title/description without rendering raw provider details.
- Show project binding, GitHub installation/repository access, executor connection, and run state as distinct setup facts; do not display installation tokens or raw provider payloads.

- [ ] **Step 1: Write failing event tests** for each new category/stage and rejection of unrecognized/raw provider details.
- [ ] **Step 2: Run `cd platform && mix test test/dev_orchestrator/event_test.exs`** and confirm the additions fail.
- [ ] **Step 3: Implement event category/stage allowlists and dashboard copy** for checkout/auth failures before Codex begins.
- [ ] **Step 4: Add LiveView assertions** showing the user which setup layer is missing and confirming blocked checkout is not rendered as a generic Codex failure.
- [ ] **Step 5: Update connector, project setup, credential scope, managed workspace, and recovery docs**. Remove instructions that require a local source path, manual `allow`, or local `gh auth` for normal operation.
- [ ] **Step 6: Run event and LiveView tests** and confirm they pass.

### Task 5: Verify integrated flow and compatibility

**Files:**
- Modify: `connector/test/worker.test.ts`
- Modify: `platform/test/dev_orchestrator/runs_test.exs`
- Modify: `platform/test/dev_orchestrator/verification_test.exs` only if candidate verification needs a regression case
- Modify: `docs/implementation-status.md`

**Interfaces:**
- Keep `/executor/claim`, `/executor/renew`, `/executor/events`, and `/executor/reconcile` payloads free of credentials.
- Preserve `task/<run-id>` branch naming, candidate event fields, project concurrency limits, and independent PR verification.
- Clean acknowledged successful worktrees after 24 hours and failed/blocked worktrees after 7 days; never clean a worktree referenced by a live lease or active journal. Keep bare repository caches until explicit connector data cleanup.

- [ ] **Step 1: Add an end-to-end connector test** covering lease → checkout token → managed worktree → Codex completion → publish token → PR candidate, with no source mapping and no `gh` executable available.
- [ ] **Step 2: Run `cd connector && npm test`** and confirm the entire connector suite passes.
- [ ] **Step 3: Add/adjust server tests** proving candidate verification remains tied to the exact open PR and that a credential response cannot alter run state or event sequencing.
- [ ] **Step 4: Run `cd platform && mix test`** and confirm the entire platform suite passes.
- [ ] **Step 5: Run `cd connector && npm run check`** and confirm TypeScript checking passes.
- [ ] **Step 6: Review `git diff --check` and the final diff**; confirm no existing user changes were staged or committed.
- [ ] **Step 7: Update `docs/implementation-status.md`** with implemented capability, required GitHub App permissions, config migration behavior, and remaining out-of-scope single-connector worker-pool limitation.
- [ ] **Step 8: Commit the completed task slices with Conventional Commit messages**, staging only plan-related files.

## Handoff

Implement in this session using TDD, completing each task and its test cycle before moving to the next. Do not publish, deploy, or merge as part of this plan. Use the accepted design spec as the source of truth; if implementation reveals a conflict around permissions, Git worktree metadata, or credential isolation, stop and revise the spec/plan before changing scope.
