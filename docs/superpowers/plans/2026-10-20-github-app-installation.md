# GitHub App Installation Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guide each project owner to install the configured GitHub App for the project's exact repository before connecting GitHub OAuth.

**Architecture:** Persist one-time installation state bound to owner, organization, project, session, and repository. Verify GitHub's returned installation ID with the configured App JWT, exchange it for an installation token, and confirm exact repository access before saving project-scoped installation metadata. The project page derives whether to show Install, Connect, or Connected from that metadata and current repository.

**Tech Stack:** Elixir, Phoenix LiveView/Controller, PostgreSQL via the existing `Store`, Req-backed GitHub API transport, ExUnit.

**Spec:** `docs/superpowers/specs/2026-10-20-github-app-installation-flow-design.md`

## Global Constraints

- Do not trust `installation_id` merely because GitHub included it in a query parameter.
- Installation state is one-time, short-lived, session-bound, project-bound, and repository-bound.
- Only an owner can install or connect provider accounts.
- Never expose credentials or App tokens in UI/API responses or logs.
- Only verified access to the project's exact repository counts as installed.
- GitHub OAuth remains separate from App installation and remains required to connect the user's account.

## Review Focus

- Spoofed installation IDs must fail when App token creation fails; cover with provider transport test.
- An installation missing the exact repository must fail; cover with provider transport test.
- A state replay, expired state, wrong session, or repository changed during installation must not save metadata; cover in `ConnectionsTest`.
- A cross-organization project ID or non-owner must not create installation state; cover in `ConnectionsTest`.
- A previously verified installation for a different repository must not show the OAuth action; cover in LiveView test.

---

### Task 1: Verify GitHub App installations and persist project setup state

**Files:**
- Create: `platform/priv/repo/migrations/20261020000000_create_github_app_installations.exs`
- Modify: `platform/lib/dev_orchestrator/connections/github.ex`
- Modify: `platform/lib/dev_orchestrator/connections.ex`
- Test: `platform/test/dev_orchestrator/provider_test.exs`
- Test: `platform/test/dev_orchestrator/connections_test.exs`

**Interfaces:**
- Produce `GitHub.verify_installation(installation_id, repository) :: {:ok, %{installation_id: integer, account: binary}} | {:error, atom}`. It authenticates with the configured App JWT, obtains an installation token, and verifies exact repository membership; return only verified metadata.
- Produce `Connections.start_github_installation(scope, project_id, session) :: {:ok, installation_url} | {:error, atom}`.
- Produce `Connections.complete_github_installation(scope, state, installation_id, session) :: {:ok, project_id} | {:error, atom}` so the callback can redirect using the project identity recovered from validated state.
- Produce `Connections.github_status(scope, project_id) :: :not_installed | :installed | :connected`, matching persisted repository metadata to the project's current repository.

- [ ] **Step 1: Write failing GitHub provider tests** for valid installation verification, a rejected/spoofed installation ID, and an installation token that lacks the exact repository. Use the existing `:provider_transport` seam and test-only generated App key material; assert no token is returned.
- [ ] **Step 2: Run `cd platform && mix test test/dev_orchestrator/provider_test.exs`** and confirm those tests fail because verification is not implemented.
- [ ] **Step 3: Implement `GitHub.verify_installation/2`** using App JWT → `POST /app/installations/:id/access_tokens` → `GET /installation/repositories?per_page=100`; reject missing exact repository and lists larger than the supported 100-repository boundary.
- [ ] **Step 4: Run the provider tests** and confirm they pass.
- [ ] **Step 5: Write failing state/persistence tests** for owner-only start, cross-tenant rejection, one-time session-bound state, captured repository, verified install persistence, replay rejection, and repository-change mismatch.
- [ ] **Step 6: Run `cd platform && mix test test/dev_orchestrator/connections_test.exs`** and confirm the new tests fail for missing installation-state behavior.
- [ ] **Step 7: Add migration tables** `github_install_states` and `github_app_installations`. Store only a digest of random state, tenant/user/project IDs, session digest, captured repository and expiry; installation records contain project, repository-at-verification, installation ID, account login and verification timestamp. Use composite tenant/project foreign keys and one installation record per project.
- [ ] **Step 8: Implement the three `Connections` functions**. Consume state atomically; re-read the project and reject repository changes; call `GitHub.verify_installation/2` before persisting; never save provider tokens.
- [ ] **Step 9: Run `cd platform && mix test test/dev_orchestrator/connections_test.exs`** and confirm all new tests pass.

### Task 2: Add the GitHub installation start and setup callback routes

**Files:**
- Modify: `platform/lib/dev_orchestrator_web/router.ex`
- Modify: `platform/lib/dev_orchestrator_web/controllers/oauth_controller.ex`
- Test: `platform/test/dev_orchestrator_web/controllers/github_install_controller_test.exs`

**Interfaces:**
- Consume `Connections.start_github_installation/3` and `Connections.complete_github_installation/4` from Task 1.
- POST `/connections/github/install/start` accepts `project_id` and redirects to GitHub's configured App install URL with opaque state.
- GET `/connections/github/install/callback` accepts `state` and `installation_id`, then redirects back to the associated project with a success or actionable error flash.

- [ ] **Step 1: Write failing controller tests** for owner start redirect, successful setup callback redirect, rejected callback state, and missing repository access; test with the existing provider transport and authenticated test session.
- [ ] **Step 2: Run `cd platform && mix test test/dev_orchestrator_web/controllers/github_install_controller_test.exs`** and confirm the routes/controller behavior is missing.
- [ ] **Step 3: Add the two authenticated routes and controller actions**. Keep state validation in `Connections`; do not accept project or repository identity from callback query parameters.
- [ ] **Step 4: Run the controller tests** and confirm success/error flashes and project redirects are correct.

### Task 3: Expose Install → Connect → Connected in the project UI and document setup

**Files:**
- Modify: `platform/lib/dev_orchestrator_web/live/dashboard_live.ex`
- Modify: `platform/test/dev_orchestrator_web/live/project_live_test.exs`
- Modify: `docs/connections.md`

**Interfaces:**
- Consume `Connections.github_status/2` while loading a selected project.
- Render **Install GitHub App** for configured-but-unverified repositories, **Connect GitHub** after verified installation, and **GitHub connected** when a non-revoked project grant exists. Keep non-owner and missing-server-configuration states disabled with explanation.
- Document the exact one-time GitHub App Setup URL: `<PUBLIC_URL>/connections/github/install/callback`, distinct from the OAuth callback, plus the existing 100-repository boundary.

- [ ] **Step 1: Write failing LiveView tests** for not-installed, installed, connected, changed-repository, non-owner, and unconfigured states.
- [ ] **Step 2: Run `cd platform && mix test test/dev_orchestrator_web/live/project_live_test.exs`** and confirm the new state assertions fail.
- [ ] **Step 3: Assign `github_status` in the project refresh path** and render the appropriate action/form for each state. Keep Linear and Slack controls unchanged.
- [ ] **Step 4: Update `docs/connections.md`** with App Setup URL configuration and the distinction between setup and OAuth callback URLs.
- [ ] **Step 5: Run `cd platform && mix test`** and confirm all platform tests pass; run `cd connector && npm test` as required by repository instructions and report any unrelated/infrastructure failure.

## Handoff

Implement natively in this session, task by task, following TDD. Run the full platform and connector suites at the end. Do not publish or deploy as part of this change.
