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
| `/executor/events` | `lease`, sequenced `event` | `data.state` or `data: "duplicate"` |
| `/executor/reconcile` | `lease`, journal summary with optional pending event | `data.action` |

A lease contains `id`, `project_id`, `generation`, `lifecycle`, `sequence`,
`expires_in_ms` (90,000), task title/prompt and immutable project `snapshot`.
The snapshot includes the project's saved `instructions` text. The connector
uses that value in the isolated task checkout; it does not fetch mutable project
rules while a task is running. Existing projects with empty instructions remain
compatible, and subsequent runs receive a replacement only after the owner saves
it. The app accepts a non-empty UTF-8 Markdown `instructions.md` file up to
32,000 bytes when creating or updating project guidance.
The snapshot never contains credentials or a server-selected executable path.

Events are `started`, `progress`, `failure`, `blocked`, `candidate`, `no_changes`.
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

The current connector uses one journal and one task slot per enrolled process.
Each distinct machine must have a distinct enrollment. Parallel tasks use distinct
executors and task checkouts, bounded by the server's per-project concurrency.
