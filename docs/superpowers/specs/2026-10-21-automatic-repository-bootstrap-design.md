# Automatic repository bootstrap for local executors

## Intent

Make the local executor usable for a project even when the user has never
cloned that repository onto the executor machine. The web project configuration
and the installed GitHub App are the source of truth for repository identity
and access. The executor should require one-time pairing and a healthy local
Codex installation, not a manually prepared checkout or a per-project `allow`
command.

The executor remains customer-owned and connects outbound to the cloud control
plane. Codex continues to run locally under the user's signed-in account. This
change does not alter the user's separate Symphony installation or global
Codex/provider configuration.

## Current behavior and cause

- `connector/src/worker.ts` looks up a project mapping in the local connector
  config and emits `local_policy_denied` when it is absent.
- `connector/src/workspace.ts` requires a canonical source checkout, verifies
  its `origin`, and clones that local path into a task workspace.
- `connector/src/cli.ts allow` requires the user to provide the project ID,
  repository, source checkout, and workspace root.
- `connector/src/publisher.ts` depends on local `gh` authentication for both
  pushing the branch and opening the pull request.
- `platform/lib/dev_orchestrator/connections/github.ex` can mint GitHub App
  installation tokens, but currently does not narrow those tokens to one
  repository or a minimal permission set.

Therefore a correctly connected cloud project can still block before Codex
starts if the executor has not been manually mapped. Missing local Git identity
may also block workspace creation because it is copied from the source repo.

## Selected architecture

Keep a hybrid topology: the cloud control plane owns task intake, project
configuration, lease/fencing, and status; a paired local executor owns source
checkout and Codex execution. The connector polls over outbound HTTPS and
creates its own workspaces under a fixed, owner-only application directory.
This follows the established control-plane/agent pattern used by systems such
as Buildkite while preserving local execution.

The selected design is a direct GitHub App bootstrap, not a local-repository
cache prerequisite and not a cloud-hosted coding runner:

1. An owner installs the configured GitHub App for the repository and selects
   that repository and base branch in the project's web settings.
2. The owner pairs the local executor and binds the project to it in the web
   app. This is the one-time authorization to run the selected project on that
   machine; no `allow --source ...` step is required.
3. The connector claims a lease. The server validates that the executor is
   bound to the project and that its verified GitHub App installation still
   matches the lease's immutable repository snapshot.
4. The connector requests a short-lived GitHub installation token for exactly
   that repository and only the permissions needed for checkout/publication.
   The token is never included in the lease, Codex prompt/environment, journal,
   activity events, or logs.
5. The connector fetches the selected base branch from GitHub into a
   connector-managed repository cache, then creates an isolated Git worktree
   and task branch. A task must never edit another task's working directory.
6. Codex executes in that worktree with the existing project sandbox and
   instructions. After Codex exits, the trusted connector checks the commit,
   obtains a fresh narrowly scoped installation token, pushes the branch, and
   creates or verifies the PR. The existing control-plane PR verification
   remains authoritative for success.
7. The connector reports safe progress/final status and retains or cleans the
   worktree according to a documented retention policy.

## GitHub credentials and authorship

- Use the already-configured GitHub App installation, not the user's local
  `gh` session and not a broad personal access token.
- Mint installation tokens scoped to the repository in the lease snapshot and
  to the minimum required permissions. Checkout needs repository contents
  read; branch push needs contents write; PR creation needs pull requests
  write. Do not request organization-wide administration access.
- The token endpoint is executor-authenticated and lease-bound. It rejects
  expired/revoked leases, an executor/project mismatch, repository mismatch,
  and an installation no longer verified for the project. Tokens are
  short-lived, memory-only from the connector's perspective, and never
  persisted in URLs or Git remotes.
- The connector performs authenticated Git/API operations outside Codex's
  process lifetime so the agent cannot read the token. Repository hooks and
  credential helpers from the checkout remain disabled for trusted publishing.
- Commits use the configured GitHub App bot identity so a local `.git/config`,
  global `user.name`/`user.email`, and pre-existing checkout are not required.
  The PR clearly identifies the app as the actor. A future product option may
  allow a project owner to select a different commit identity.

## Workspace layout, cache, and concurrency

- The connector owns a stable root below its application data directory, with
  restrictive permissions and no user-supplied arbitrary filesystem path.
- Cache repository objects per project/repository to avoid repeated full
  downloads; serialize cache fetch/update operations. Each run gets a distinct
  Git worktree and branch, keyed by run ID and lifecycle, so parallel jobs do
  not share a mutable checkout.
- Clean a worktree only after a terminal result is acknowledged and after the
  configured retention window; preserve failed/incomplete work for diagnosis.
  Cache garbage collection must not remove live or recoverable worktrees.
- Project concurrency remains enforced by the server. Distinct executor
  processes may claim concurrent runs up to that limit. This change does not
  introduce multiple worker slots inside one connector process; that can be a
  separately scoped enhancement. The checkout design must not prevent that
  future worker-pool model.

## Protocol and compatibility

- Remove repository source paths and per-project local mappings from the
  required connector configuration. Pairing remains machine-scoped; project
  authorization is represented by server-side executor bindings.
- Introduce an authenticated, lease-bound repository credential operation (or
  equivalent narrow endpoint) that returns only a scoped, expiring token. It
  must not change the general lease payload or event schemas to carry secrets.
- Keep old connector config readable during migration, but ignore/deprecate
  `mappings` and `allow`; emit a clear migration message rather than silently
  trusting stale source paths. Bump protocol/config versions only if required
  by the new endpoint semantics, and reject unsupported versions explicitly.
- Keep task branch naming, commit validation, event sequencing, cancellation,
  lease renewal/fencing, and independent server PR verification intact.
- Existing project settings already provide repository and base branch. If the
  project repository changes, any previous installation binding must not
  authorize the new repository.

## Failure behavior and observability

Report actionable blocked states before Codex starts: GitHub App not installed
for the selected repository, project not bound to this executor, invalid or
revoked lease, insufficient App permissions, base branch missing, GitHub
temporarily unavailable, or local disk/worktree failure. Do not classify these
as generic Codex failures and do not retry an identical permanent error
indefinitely.

Emit a first progress event as soon as the lease is accepted, then safe
milestones for repository preparation, worktree ready, Codex stages, checks,
publishing, and PR verification. Never forward raw command output, secrets,
full prompts, or private reasoning. A failed checkout must not leave the UI
waiting for the first activity update.

## Acceptance criteria

1. A fresh paired executor with Codex authenticated and Git installed can run
   an authorized project task without the repository being locally present and
   without a manual `allow` command.
2. The connector downloads the exact repository/base branch from the lease
   snapshot and creates a distinct task branch/worktree in its managed root.
3. Two authorized executors can work on separate tasks in the same project
   concurrently up to the project's configured concurrency, without sharing
   a worktree or branch.
4. A missing/stale installation, wrong repository, wrong executor binding,
   insufficient permission, missing base branch, and transient GitHub failure
   each produce a specific actionable status; no Codex process starts before
   repository validation succeeds.
5. GitHub tokens are scoped to the exact repository/minimal permissions,
   excluded from persisted state and events, unavailable to the Codex child
   process, and absent from `.git/config` after every operation.
6. The connector can commit, push, and create/verify an open PR using the
   GitHub App without `gh` being installed or authenticated and without a
   source checkout or local Git author configuration.
7. Existing idempotency, lease fencing, cancellation, journal recovery,
   candidate verification, and progress streaming tests continue to pass.
8. The dashboard clearly distinguishes project binding, GitHub App/repository
   authorization, executor connectivity, and task execution health.

## Out of scope

- Cloud-hosted code execution, billing, or deployment.
- Changing how users authenticate to Codex; the local connector continues to
  use the user's local Codex login.
- Creating, merging, or force-pushing PRs; the existing branch-and-open-PR
  handoff is retained.
- Multiple worker slots within one connector process, custom remote caches,
  project templates, and organization-wide runner administration.
- Relaxing the Codex sandbox or exposing GitHub credentials to the agent.

## Test strategy

- Add connector tests for fresh checkout without a source mapping, cache/worktree
  identity, isolation between runs, token non-persistence, and Codex not
  receiving credentials.
- Add server tests for lease-bound token minting, exact repository scoping,
  minimum requested permissions, executor/project binding, lease expiry and
  revocation, installation/repository mismatch, and token responses never
  entering event or journal payloads.
- Add publisher tests proving App-token push/PR operations work without `gh`,
  use the expected repo/base/head/commit, and leave no credential in the remote
  URL or Git config.
- Retain and run the complete platform and connector suites. Provider-backed
  smoke tests remain opt-in and must never print tokens.
