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
Grant repository metadata read and pull requests read permissions for verification.
The customer host's separate GitHub CLI credentials perform publication; the cloud
does not receive those credentials. The app's private key is used only by the cloud
to mint short-lived installation tokens.

Set `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GITHUB_APP_ID`, `GITHUB_APP_SLUG`
and `GITHUB_PRIVATE_KEY_PATH`. Mount that private key read-only into the container
using an operator-owned Compose override or secret mount; never add it to this repo.

From the project page, choose **Install GitHub App** and grant access to that
project's repository. The platform verifies the installation and then shows
**Connect GitHub** to authorize the user's account. OAuth verifies that the user
can access an installation containing the project's repository. This initial
version supports installation/repository lists of up to 100 entries and fails
closed for larger lists; use a narrowly scoped installation for evaluation.

## Linear

Register an OAuth application with callback `PUBLIC_URL/connections/linear/callback`.
Set `LINEAR_CLIENT_ID`, `LINEAR_CLIENT_SECRET` and `LINEAR_WEBHOOK_SECRET`.
The requested scopes are `read,write`; admin scope is not requested. Refresh tokens
are stored encrypted and rotated when their access tokens expire.

Connect from the project. Configure its exact Linear team ID, optional project ID
and review-state name. The initial eligible intake states are `Todo` and `In Progress`.
Create an Issue create/update webhook pointing to
`PUBLIC_URL/api/v1/webhooks/linear/CONNECTION_ID` for that authorized connection.
The connection ID is visible on the connections screen. Use the configured webhook
signing secret. The payload organization must match the authorized Linear account;
query parameters cannot override signed webhook data.

Only freshly signed events are accepted. A duplicate issue does not start another
run automatically. Successful verified PRs are attached and moved to the configured
review state. Failed work remains visible without falsely marking the issue done.

## Slack

Register an OAuth Slack app with callback `PUBLIC_URL/connections/slack/callback`.
Set `SLACK_CLIENT_ID` and `SLACK_CLIENT_SECRET`. The only requested bot scope is
`chat:write`. Socket Mode, interactive approval buttons and history access are not
needed for this release's outbound final/blocker reports.

Connect the workspace from a project. Invite the bot to the destination channel
and save its channel ID (starting with C or G) in project rules. Revoking a local
connection immediately prevents the platform from using it; revoke the app at
the provider as well to invalidate the provider-issued authorization itself.

## Local Codex and GitHub CLI

Install/sign in to the official Codex CLI separately using the user's own account.
`connector status` checks account type but does not upload login files or prove
that any particular model is entitled. A completed inference turn is the access
check. Unsupported permission profiles fail rather than switching to full access.

Authenticate `gh` on the customer host and ensure the approved source checkout has
a local Git author name/email. The connector does not modify global configuration.
Do not copy provider tokens into the cloud server or into project instructions.

## Sources

- [GitHub App installation tokens](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-an-installation-access-token-for-a-github-app)
- [GitHub App setup URLs](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/about-the-setup-url)
- [Linear OAuth](https://linear.app/developers/oauth-2-0-authentication)
- [Linear webhooks](https://linear.app/developers/webhooks)
- [Slack OAuth](https://docs.slack.dev/authentication/installing-with-oauth/)
- [Codex app-server](https://learn.chatgpt.com/docs/app-server)
