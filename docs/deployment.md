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

## Free hosted evaluation (Render + Neon)

The root `render.yaml` defines a single-instance free Docker web service. It
uses the existing Phoenix release, runs database migrations at startup, and
checks `/api/v1/ready`. Keep PostgreSQL outside Render: its free database
expires after 30 days. Create a Neon project, then use its pooled connection
string as `DATABASE_URL` in Render.

This is for a first hosted evaluation, not production: Render's free web
instance sleeps after 15 minutes without inbound traffic, can restart, and has
an ephemeral filesystem. The database is durable, but keep the GitHub App key
as a Render secret file, never in the image or repository. Email is configured
for SendGrid SMTP over port 2525 because Render's free tier blocks ports 25,
465, and 587.

1. Push this repository to GitHub and create a Render Blueprint from it. Render
   reads the root `render.yaml` and asks for the values marked `sync: false`.
2. Create a Neon database and set its pooled URL as `DATABASE_URL` in the
   Render service's Environment page. Keep the URL private.
3. The Blueprint maps `PUBLIC_URL` to Render's assigned HTTPS origin. Generate
   `SECRET_KEY_BASE` locally with `openssl rand -hex 64` and
   `CONNECTION_ENCRYPTION_KEY` with `openssl rand -base64 32`; enter each value
   directly in Render, not in chat or source control. Back up the connection
   key securely because it encrypts stored provider credentials.
4. For email, create a SendGrid API key and verify the sender address/domain.
   The Blueprint sets host `smtp.sendgrid.net`, port `2525`, and username
   `apikey`; enter the API key as `SMTP_PASSWORD` and the verified sender as
   `MAIL_FROM`.
5. In Render's Secret Files, upload the GitHub App PEM as
   `/etc/secrets/github-app.pem`. Then add the GitHub, Linear, and Slack app
   credentials to the service environment. `render.yaml` includes placeholders
   for them; integrations can remain unset until configured.
6. Update each provider's callback URL to use the Render origin. GitHub OAuth:
   `/connections/github/callback`; GitHub App Setup URL:
   `/connections/github/install/callback`; Linear OAuth:
   `/connections/linear/callback`; Slack OAuth:
   `/connections/slack/callback`. Configure Linear's webhook endpoint as
   `/api/v1/webhooks/linear/CONNECTION_ID` for each authorized connection, with
   the matching signing secret in `LINEAR_WEBHOOK_SECRET`.
7. Open the Render service URL, register the owner account, verify email, then
   connect provider accounts and pair a local executor using that public URL.

Never commit populated environment files, OAuth secrets, SMTP API keys, or the
GitHub PEM. Render only prompts for `sync: false` values on initial Blueprint
creation; add or rotate them later in the service's Environment page.

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

The connector and platform have committed lockfiles. Still run the full
PostgreSQL/authentication/UI suite and provider smoke test against the deployed
environment before treating it as production-ready.
