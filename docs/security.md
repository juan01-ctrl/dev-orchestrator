# Evaluation security boundaries

The cloud source is private; the customer connector is inspectable software, not
a cryptographic secret. Do not promise that distributed binaries or prompts cannot
be reverse engineered. Commercial provider permissions are separate from local
technical feasibility.

## Enforced design

- Browser sessions are signed/encrypted cookies containing a random session token;
  the database stores only its hash. Email verification precedes authenticated
  project access. Resetting passwords invalidates active session tokens.
- Server-side scope derives organization membership from the authenticated user.
  Project-scoped queries and compound tenant foreign keys restrict data access.
- Provider secrets use AES-256-GCM with organization-specific authenticated data.
  OAuth state is single-use, expiring, bound to user, project and browser session.
- Enrollment codes expire after ten minutes, are single use and are rate-limited.
  Executor credentials are hashed on the server and stored owner-only on the host.
- Connector calls are outbound HTTPS, with no redirects or inbound remote shell.
  Loopback HTTP is allowed for development only.
- Cloud project binding and verified GitHub App installation jointly authorize
  repository access. The connector keeps a managed bare cache and creates an
  isolated worktree per task; no user-supplied local source path is trusted.
- Codex receives an environment allowlist and a project-write permission profile;
  Git metadata and project-scoped skills are writable, global provider configuration
  and credential directories are not. Outbound agent network is disabled by default;
  an exact single-host app-server amendment is accepted only when the host matches
  the deployment allowlist. Arbitrary hosts and multi-host expansions are denied.
- The control plane issues short-lived GitHub App tokens scoped to the exact
  repository and minimum purpose permissions after validating the live lease.
  Trusted Git publication uses a temporary owner-only credential helper, ignores
  task Git hooks/configuration, never force-pushes/merges, and removes the helper
  in `finally`. The cloud verifies repository/head/base/commit before accepting
  a PR result. Credentials never enter the journal, Git remotes, events or Codex.
- Durable fencing and sequence checks reject stale or duplicate run events.
  Executor revocation/cancellation takes effect on the next lease check; it does
  not magically undo an already-started external operation.

## Limits requiring review before public rollout

The full integration suite, live browser flow and actual provider delivery remain
required deployment gates. Database-level RLS, security audit, invitation flows,
encryption-key rotation, enterprise SSO and hosted customer execution are not
implemented. Organization membership is supported, but public team invitation and
organization-switching UI are intentionally deferred.

The connector supports 1–10 local task slots via `DEV_ORCHESTRATOR_SLOTS` (default
1). Each slot has its own journal and task checkout; project concurrency and
executor binding still cap effective parallelism. It preserves a PID lock after
an unclean stop; only remove that exact lock after confirming no executor process
is still using the credential. Do not copy a paired configuration across machines.
Use distinct executor enrollments for distinct machines.

The model provider receives task context, including source. Sanitized control-plane
metadata can also contain repository names and issue titles. No blanket claim of
"all code stays on your machine" is made. Do not enter secrets into task instructions.
