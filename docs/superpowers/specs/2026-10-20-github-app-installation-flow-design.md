# GitHub App installation flow

## Problem and intent

The project page currently presents one **Connect GitHub** action. That action
starts GitHub OAuth and checks for a GitHub App installation only after OAuth
returns. When the app is not installed on the selected repository, users see a
failure after completing the wrong step.

Separate the two setup steps in the project UI: install the configured GitHub
App with access to this project's repository first, then connect the user's
GitHub account with OAuth. Keep the existing OAuth authorization and repository
access checks; make installation an explicit, project-scoped prerequisite.

## User flow

1. An owner opens a project with a configured GitHub App.
2. If this configured app has not been verified for the project's current
   `owner/repository`, the page shows **Install GitHub App**.
3. The action opens the configured app's installation URL and carries a
   short-lived, one-time state value bound to the signed-in owner, organization,
   project, browser session, and repository.
4. GitHub redirects to the configured App Setup URL after installation or
   repository-access changes. The server validates and consumes the state,
   verifies the installation using the configured App credentials, and checks
   that its repository list contains the project's exact repository.
5. On success, persist the verified installation for that project/repository
   and return to the project page. The action becomes **Connect GitHub**.
6. OAuth continues as today. The callback binds the OAuth identity to the
   verified installation and grants the resulting connection to this project.
7. If repository access is missing or later revoked, do not create a GitHub
   connection; show a specific message and return the project to the install or
   configure step.

Non-owners cannot install or connect provider accounts. Missing server-side
GitHub App configuration remains visible as a setup requirement, not an active
button.

## Architecture and data

- Add an authenticated `POST` action to begin installation. It validates owner
  access and project ownership, creates a hashed one-time state record with a
  short expiry, and redirects to
  `https://github.com/apps/<configured-slug>/installations/new?state=...`.
- Add an authenticated GitHub App setup callback. It consumes state only for
  the same owner, organization, project, session, and repository captured when
  the flow began. It handles install and update callbacks; invalid, expired,
  replayed, or cross-project state cannot alter data.
- Add a project-scoped installation table (or equivalent constrained record)
  containing organization, project, repository-at-verification, installation
  ID, account login, and verification timestamp. Enforce tenant/project
  ownership with a composite foreign key. Never expose credentials or App
  tokens in UI/API responses or logs.
- Do not trust `installation_id` merely because GitHub included it in a query
  parameter. Authenticate as the configured GitHub App, request an installation
  access token for that ID, and verify that the installation can access the
  exact repository currently saved on the project before persisting it.
- When a project's repository changes, an installation record for the prior
  repository does not satisfy the new repository. Derive the UI state by
  comparing the verified repository field with the current project repository.
- Keep the existing OAuth `connections` and `connection_grants` model. GitHub
  OAuth still verifies repository access before granting a connection; the
  installation record is not itself an OAuth connection or user authorization.

## UI states and errors

For GitHub on the project page:

- Not configured: disabled action with the existing server setup guidance.
- Configured, not verified for this repository: **Install GitHub App**.
- Verified installation: **Connect GitHub** (unless a GitHub connection is
  already granted, in which case show connected state and the existing
  disconnect control where appropriate).
- GitHub installation callback success: confirmation flash and updated project
  state.
- Callback canceled, invalid, expired, or repository not included: actionable
  error that keeps the project unconnected and allows retry.

Do not represent the app as installed merely because an installation URL was
opened. Only the verified callback establishes the state.

## Configuration and operations

The GitHub App's **Setup URL** must point to
`<PUBLIC_URL>/connections/github/install/callback` (exact route to be confirmed
against the implementation). Document this one-time app-owner setting next to
the existing GitHub App environment configuration. GitHub's Setup URL is
distinct from the OAuth Callback URL already used by **Connect GitHub**.

The callback must be HTTPS in deployed environments. Local development may use
the configured public URL only if GitHub permits the corresponding callback
configuration; otherwise use an HTTPS development tunnel. Do not weaken state
validation to work around a callback URL configuration error.

## Testing and acceptance criteria

- A project without a verified installation shows **Install GitHub App**, not
  **Connect GitHub**.
- A verified installation for the exact current repository changes the action
  to **Connect GitHub**.
- A record verified for another repository does not unlock OAuth for the
  current repository.
- The start action requires an owner and a project within that owner's
  organization; members and cross-tenant project IDs cannot start installation.
- Callback state is one-time, session-bound, project-bound, repository-bound,
  and expires; invalid/replayed state makes no database changes.
- A spoofed installation ID, an installation belonging to a different app, or
  an installation without access to the repository is rejected.
- Successful callback records only verified installation metadata, not tokens.
- Existing OAuth identity binding and project connection grants remain covered
  by tests and continue to reject missing repository access.
- UI errors explain whether the user must install the app, select the repo, or
  reconnect OAuth.
