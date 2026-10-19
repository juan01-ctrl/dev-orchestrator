# Run the private cloud control plane

Do not expose this application until the complete PostgreSQL/authentication/UI
suite and the designated provider smoke test have passed. The code and container
configuration are not evidence of a successfully tested deployment.

## Local development

`compose.yaml` starts an isolated evaluation database on loopback port 5433.
The web app starts separately on 4100. Development uses a local email preview
and a development-only encryption key; neither is a production setting.

## Production-shaped evaluation

Use `compose.cloud.yaml` behind your HTTPS reverse proxy. Public port 4100 is not
opened directly: the web port is bound to loopback. Preserve WebSocket upgrade
headers and configure a certificate for `PUBLIC_URL`. The database is not published.

Required environment variables:

| Variable | Requirement |
|---|---|
| `PUBLIC_URL` | HTTPS origin, no path/query/userinfo |
| `DATABASE_URL` | PostgreSQL URL; service hostname is `database` in Compose |
| `POSTGRES_PASSWORD` | Unique database password supplied to the database service |
| `SECRET_KEY_BASE` | At least 64 bytes of random session-signing/encryption material |
| `CONNECTION_ENCRYPTION_KEY` | Base64-encoded 32 random bytes; back it up securely |
| `SMTP_HOST`, `SMTP_PORT` | SMTP endpoint; default port 587 |
| `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM` | Account verification/reset delivery |

Generate secrets locally using a password manager or your deployment's secret
manager. Store them outside source control. Supply provider-app variables only
for integrations you are enabling; see [connections](connections.md).

Build, migrate explicitly, then start:

```bash
docker compose -f compose.cloud.yaml build web
docker compose -f compose.cloud.yaml run --rm web \
  bin/dev_orchestrator eval 'DevOrchestrator.Release.migrate()'
docker compose -f compose.cloud.yaml up -d
```

If enabling GitHub, pass an operator-owned override file in all three commands
to mount its private key read-only at `GITHUB_PRIVATE_KEY_PATH` inside the container.
Do not place the key in the build context.

`GET /api/v1/health` checks the web process; `/api/v1/ready` also checks database
access. Provider authorization is a separate check, not implied by readiness.

## Backup and recovery

Back up PostgreSQL and the connection-encryption key separately. Restoring only
the database cannot decrypt connection credentials without the original key.
Retain the session key to preserve sessions; rotate it deliberately to invalidate
all browser sessions. Key rotation for connection secrets needs re-encryption and
is not an automatic feature of this evaluation.

On restart, queued tasks remain queued. Active expired leases wait for executor
reconciliation; they are not reassigned automatically. Do not delete preserved
customer workspaces to clear a task. Unknown Slack send outcomes remain ambiguous,
not silently resent. Inspect the outbox before deciding whether to resend manually.

## Reproducibility and current validation limits

The connector has a lockfile. The platform dependency lockfile must be resolved
and committed from the first successful `mix deps.get`; package access was blocked
in the implementation harness. Until that is done and the full checks pass,
this is not a reproducibly verified server build.
