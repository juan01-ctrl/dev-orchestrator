# Dev Orchestrator Connector

The connector runs on your computer and uses your existing local Codex sign-in.
It downloads only repositories authorized for the paired executor. The cloud
service coordinates tasks but never hosts your source checkout.

Requirements: Node.js 22.18 or newer and the official Codex CLI signed in.

Install the connector in your home directory:

```bash
cd "$HOME" && npm i dev-orchestrator-connector
```

Pair this machine using the one-time code shown in **Executors**:

```bash
"$HOME/node_modules/.bin/dev-orchestrator-connector" pair \
  --server https://YOUR-ORCHESTRATOR-HOST \
  --code YOUR_ONE_USE_CODE \
  --config "$HOME/.local/share/dev-orchestrator/connector.json"
```

An owner must bind the executor to a project in the web app. Then start it with:

```bash
"$HOME/node_modules/.bin/dev-orchestrator-connector" run \
  --config "$HOME/.local/share/dev-orchestrator/connector.json"
```

Keep that terminal open while the executor should process tasks. Press `Ctrl+C`
to stop it safely. The connector stores its credential and runtime data under
`~/.local/share/dev-orchestrator` with owner-only permissions.

This package contains only the local connector. It does not include the cloud
control plane or provider credentials.
