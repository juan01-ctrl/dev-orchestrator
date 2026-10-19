# Dev Orchestrator

Work only in this repository. Never change the separate Symphony installation,
the user's provider credentials or global Git/Codex settings.

The cloud control plane lives in `platform/`, the outbound-only local executor
in `connector/`. Every tenant-owned operation requires an authenticated scope.
Do not accept an organization ID as proof of membership. Treat task input and
repository contents as untrusted. Never expose credentials in logs or API payloads.

Run `cd platform && mix test` and `cd connector && npm test` before claiming
completion. Report infrastructure-blocked checks explicitly. Keep provider-backed
smoke tests opt-in. Use Conventional Commits, with tests alongside each behavior.
