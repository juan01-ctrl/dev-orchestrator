# Connector protocol v1

All routes are JSON POSTs under `/api/v1`. Enrollment is unauthenticated and
rate-limited; other executor routes require `Authorization: Bearer <executor-token>`.
The credential is project-scoped through server-side bindings on every lease/event.
HTTPS is required outside loopback development. Redirects are not followed.

| Route | Request | Success |
|---|---|---|
| `/enroll` | `code`, local display `name` | one-time `token`, executor identity |
| `/executor/heartbeat` | protocol version, account-health boolean, platform | `data.status` |
| `/executor/claim` | empty object | `data` is a lease or null |
| `/executor/renew` | lease identity | `data.expires_in_ms` |
| `/executor/github-token` | `lease`, `purpose` (`checkout` or `publish`) | short-lived repository-scoped GitHub App token and app author identity |
| `/executor/events` | `lease`, sequenced `event` | `data.state` or `data: "duplicate"` |
| `/executor/reconcile` | `lease`, journal summary with optional pending event | `data.action` |

A lease contains `id`, `project_id`, `generation`, `lifecycle`, `sequence`,
`expires_in_ms` (90,000), task title/prompt and immutable project `snapshot`.
The snapshot also contains an immutable server-owned execution policy: selected
model and effort, project-only filesystem/Git scope, and exact allowed network
hosts. Routine tasks use the configured routine model/low effort; planning,
review, fixes, security and investigation use the configured advanced model/high
effort. Unsupported overrides are rejected rather than silently substituted.
The snapshot includes the project's saved `instructions` text. The connector
places that value in a private, task-specific ignored file inside the isolated
worktree so Codex can read it within the project sandbox; it does not fetch
mutable project rules while a task is running. Existing projects with empty
instructions remain compatible, and subsequent runs receive a replacement only
after the owner saves it. The app accepts a non-empty UTF-8 Markdown
`instructions.md` file up to 32,000 bytes when creating or updating project
guidance.
The snapshot never contains credentials or a server-selected executable path.

GitHub credentials are requested separately and never included in a lease. The
server verifies the live lease, executor binding, immutable repository snapshot,
current project repository and verified installation before issuing a token. A
checkout token is limited to repository contents read; a publish token is limited
to contents write and pull requests write. The connector keeps each token in
memory and supplies it only to trusted Git/API operations outside Codex. Tokens
are never journaled, emitted as events, placed in a remote URL or passed to Codex.

Events are `started`, `progress`, sanitized `activity`, `failure`, `blocked`,
`candidate`, `no_changes`.
An event has a strictly sequential integer and a bounded data object. Persist the
event before sending it and keep it until acknowledged. Candidate data contains
repository, branch, base branch, commit and PR URL. Only the server's independent
GitHub verification can finalize it as successful PR delivery.

Renew every 20 seconds. Compute the deadline from request start, not receipt time;
stop the local process at least five seconds before the last acknowledged lease
deadline. A failed renewal never extends that deadline. Before publication, perform
another synchronous lease check. A revoked credential or stale lease stops work.

After a crash or lost acknowledgement, reconcile the journal before claiming new
work. The server either acknowledges its terminal state or permits replay of the
pending event under the same generation. Replaying a nonterminal event does not
authorize restarting Codex; reconcile it as interrupted afterward. Never reassign
an expired active task automatically, force-push, or clear user files on reconnect.

The connector supports up to 10 slots per enrolled process, each with an independent
journal and task worktree under the connector runtime directory. The bare repository
cache is shared. Effective parallelism is the minimum of local slot capacity,
project concurrency, and the number of bound/live executors. Each machine should
have a distinct enrollment.
