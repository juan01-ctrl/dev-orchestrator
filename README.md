# dev-orchestrator

Private cloud coordination for development tasks, with customer-owned local Codex
execution. Separate users, projects, integration grants, rules and task histories.
The local connector uses an independently installed Codex CLI and the customer's
existing account. No inference API key is required for this private evaluation.

**Evaluation status:** implementation is in progress. Connector unit/process/Git
tests and pure server checks can run offline. Full PostgreSQL/auth/UI integration,
container startup and provider-backed delivery must pass before this is treated
as a working deployment. Do not expose this evaluation publicly yet.

## Start a local evaluation

Requirements: Docker Desktop running, Elixir 1.19/OTP 28 (provided by `mise.toml`),
Node.js 22.18+, Git and the official Codex CLI signed in to the user's account.
This application uses port **4100** and a separate PostgreSQL instance on **5433**.
It does not use or modify an existing Symphony installation or port 4000.

```bash
docker compose up -d database
cd platform
mise exec -- mix setup
mise exec -- mix assets.copy
mise exec -- mix phx.server
```

Open [the application](http://localhost:4100), register a workspace and verify
the email through the local [development mailbox](http://localhost:4100/dev/mailbox).
When creating a project, download the `instructions.md` template, tailor it to
the repository, and upload it with the repository and PR target branch. Existing
projects can replace their instructions from **Project rules**. Changes apply
to future task runs; active runs keep the instructions they already received.
The upload must be a non-empty UTF-8 Markdown file named `instructions.md` and
no larger than 32 KB.

For service integrations, first configure your own provider applications as
described in [connections](docs/connections.md). Missing configuration is shown
honestly as `App not configured`; no test integration is displayed as live.

## Pair a real local executor

In the web app, open **Executors → Create pairing code**. On the customer machine,
create a dedicated directory for connector credentials, then run:

```bash
cd connector
npm ci --ignore-scripts
mkdir -p "$HOME/.local/share/dev-orchestrator"
node --experimental-strip-types src/cli.ts pair \
  --server http://localhost:4100 --code YOUR_ONE_USE_CODE \
  --config "$HOME/.local/share/dev-orchestrator/connector.json"
```

Pairing does not grant project access. An owner must bind the executor to the
project and install the configured GitHub App for that project's repository.
The connector downloads the selected repository itself; no local clone or `allow`
command is needed:

```bash
node --experimental-strip-types src/cli.ts status \
  --config "$HOME/.local/share/dev-orchestrator/connector.json"

node --experimental-strip-types src/cli.ts run \
  --config "$HOME/.local/share/dev-orchestrator/connector.json"
```

The connector keeps a bare repository cache and creates an isolated task worktree
inside its managed data directory. It requests short-lived, repository-scoped
GitHub App credentials for checkout and publication; credentials stay out of
Codex, the connector journal and Git remotes. No local `gh` authentication or Git
author setup is required. One connector runs one task at a time; multiple
connectors allow parallel work subject to per-project limits. Its dedicated Codex
subprocess does not attach to desktop chats.

## Verification

```bash
cd platform
mise exec -- mix test
mise exec -- mix format --check-formatted

cd ../connector
npm ci --ignore-scripts
npm run check
npm test
```

With no database, `cd platform && mise exec -- elixir test/offline.exs` checks pure
validation, encryption, PR matching, signatures and provider-response behavior.
It does **not** verify authentication, tenant queries, migrations or concurrency.
Provider-backed smoke tests require a designated test repository/channel and
configured provider apps; automated tests never use your real accounts.

## Boundaries

- Three equivalent task failures stop automatic work and enqueue one final report.
- Disconnection preserves files and journals. Expired active work waits for
  reconciliation instead of being assigned again blindly.
- No force push, automatic merge, deployment, billing, hosted executors or Claude
  adapter is included. The agent's evaluation sandbox has network disabled.
- A private local-login prototype is not a promise of commercial subscription
  eligibility; commercial provider authorization is a separate requirement.
- Repository source can reach the model provider. Only bounded, sanitized event
  metadata is sent to this control plane by default.

See [deployment](docs/deployment.md), [security](docs/security.md),
[evaluation checklist](docs/evaluation.md) and [protocol](docs/protocol.md).
