# Connect customer-owned tools

The platform sign-in, service OAuth and local Codex login are independent. Configure
provider apps in the server's environment, restart the new platform, then connect
an account from a project. No credentials are imported from the old Symphony setup.

## GitHub

Create a GitHub App, enable its user authorization flow, and configure OAuth callback
`PUBLIC_URL/connections/github/callback`. Configure its **Setup URL** as
`PUBLIC_URL/connections/github/install/callback` and enable **Redirect on update** so
repository-access changes are rechecked. Do not select **Request user authorization
(OAuth) during installation**; that option prevents GitHub from using a Setup URL.
The setup callback and OAuth callback are separate steps. Install the app only on
approved repositories.
Grant repository contents read/write and pull requests read/write permissions.
The executor requests short-lived installation tokens for the exact configured
repository: checkout tokens receive contents read; publication tokens receive
contents write and pull requests write. The app's private key stays on the cloud
and is used only to mint those scoped tokens.

Set `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_APP_ID`, `GITHUB_APP_SLUG`
and `GITHUB_PRIVATE_KEY_PATH`. Mount that private key read-only into the container
using an operator-owned Compose override or secret mount; never add it to this repo.

From the project page, choose **Install GitHub App** and grant access to that
project's repository. The platform verifies the installation and then shows
**Connect GitHub** to authorize the user's account. OAuth verifies that the user
can access an installation containing the project's repository. This initial
version supports installation/repository lists of up to 100 entries and fails
closed for larger lists; use a narrowly scoped installation for evaluation.
The executor uses the project's saved repository and base branch to fetch code;
users do not need to clone the repository or configure local GitHub CLI access.

## Linear

Register an OAuth application with callback `PUBLIC_URL/connections/linear/callback`.
Set `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET` and `LINEAR_WEBHOOK_SECRET`.
The requested scopes are `read,write`; admin scope is not requested. Refresh tokens
are stored encrypted and rotated when their access tokens expire.

Connect from the project. Configure its exact Linear team ID, optional project ID
and review-state name. The initial eligible intake states are `Todo` and `In Progress`.
Configure an Issue create/update webhook pointing to
`PUBLIC_URL/api/v1/webhooks/linear`. This provider-wide endpoint routes the signed
organization ID to matching connected workspaces and project grants. The service
verifies the exact raw body and timestamp, persists a minimal event in a durable
inbox, and acknowledges it before doing Linear API lookups asynchronously. Do not
put identity or secrets in query parameters.

Only freshly signed events are accepted. A duplicate issue does not start another
run automatically. Successful verified PRs are attached and moved to the configured
review state. Failed work remains visible without falsely marking the issue done.

## Slack

Register an OAuth Slack app with callback `PUBLIC_URL/connections/slack/callback`.
Set `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET` and `SLACK_SIGNING_SECRET`. The bot
requests `chat:write`, `channels:read`, `groups:read`, `app_mentions:read` and
`files:read`. Channel scopes list channels the bot has joined; the added scopes
receive explicit mentions and download attached files. The app does not read
channel history. Configure both the Events API Request URL and Interactivity
Request URL as `PUBLIC_URL/api/v1/webhooks/slack`, and subscribe to `app_mention`.
Reconnect existing Slack grants after the new scopes are added.

Connect the workspace from a project, invite the bot to the destination channel,
then choose that channel from the project's report-channel selector and save the
project rules. Only non-archived channels where the bot is already a member are
listed. If an existing connection was installed before channel scopes were
added, reconnect Slack to grant them. A Slack channel is bound to exactly one
platform project within its workspace. To create a task, mention the bot in that
channel with a text description, for example `@TestApp Fix the save button`,
or attach one hosted audio file (`mp3`, `mp4`, `mpeg`, `mpga`, `m4a`,
`wav` or `webm`, at most 25 MB) with optional text context. Text-only requests
skip transcription. The bot proposes a structured task in the thread;
only the original requester can create it in the configured
Linear project, and the confirmation expires after 24 hours. No Linear issue or
execution is created before confirmation. Revoking a local connection immediately
prevents the platform from using it; revoke the app at the provider as well to
invalidate the provider-issued authorization itself.

## Local Codex and managed Git workspaces

Install/sign in to the official Codex CLI separately using the user's own account.
`connector status` checks account type but does not upload login files or prove
that any particular model is entitled. A completed inference turn is the access
check. Unsupported permission profiles fail rather than switching to full access.

The local connector uses the customer's official Codex login. Keep the connector's
managed data directory writable and private; it stores a bare Git object cache,
task-specific worktrees, and recovery state there. Legacy connector config version
1 remains readable, but old per-project local mappings are ignored. Re-pairing is
not required; delete stale `allow` setup only after confirming no old connector is
running. Do not copy provider tokens into project instructions or connector config.

## Sources

- [GitHub App installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
- [GitHub App setup URLs](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/about-the-setup-url)
- [Linear OAuth](https://linear.app/developers/oauth-2-0-authentication)
- [Linear webhooks](https://linear.app/developers/webhooks)
- [Slack OAuth](https://docs.slack.dev/authentication/installing-with-oauth/)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
