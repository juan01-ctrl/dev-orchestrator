# Project instructions file

Let project owners provide durable coding guidance as a versioned Markdown
file, with a ready-to-edit template and a consistent copy in each task's
isolated checkout.

## User flow

1. A project owner downloads `instructions.md` from the project form.
2. They tailor the guidance for the repository and upload that file when
   creating the project. Existing projects can replace it from Project rules.
3. The app validates and stores its UTF-8 Markdown contents with the project.
4. Each task snapshots the saved content. The local connector writes a
   non-empty snapshot to its private task metadata directory as `WORKFLOW.md`
   and tells the coding agent to read it before acting. A legacy project with
   no saved instructions keeps its current behavior until its owner uploads a
   file; it remains executable during rollout.

The UI, downloaded template and customer-facing validation messages use only
`instructions.md`. The generated internal file stays outside Git's tracked
working tree so it cannot appear in a task's commit or pull request. Repository
`AGENTS.md` files and project skills remain available and take precedence where
they define repository-specific requirements; the uploaded file adds project
guidance rather than replacing them.

## Downloadable template

The template is plain Markdown with no vendor, product, service or internal
implementation references. It gives teams practical sections for project
context, repository rules, implementation and validation, Git delivery, and
completion reports:

```markdown
# Project instructions

## Project context

<!-- What this project does and any important domain constraints. -->

## Repository guidance

- Read and follow the repository's AGENTS.md files and project-scoped skills.
- Keep changes focused on the requested task and within this repository.
- Follow existing architecture, naming, formatting and testing conventions.
- Do not change global tools, credentials, or unrelated projects.

## Implementation

- Inspect the affected code and nearby tests before making changes.
- Make the smallest complete change that meets the task requirements.
- Ask for more context only when a missing decision blocks safe progress.
- Do not include secrets or personal data in files, logs, or task reports.

## Validation

- Run the checks relevant to the files changed.
- Add or update tests when behavior changes.
- Report checks that could not run and why; never claim an unrun check passed.

## Git and delivery

- Work on the task's assigned branch.
- Use a clear, conventional commit message.
- Prepare a pull request against the configured target branch when the task is
  complete and contains changes.
- Do not merge, deploy, or make destructive changes.

## Completion report

Summarize the change, validation results, and pull request link. If blocked,
state the specific blocker and what information or access is missing.
```

The template is a starting point. Comments are editing hints only and contain
no product attribution.

## Storage and execution

Keep the existing project `instructions` column and lease snapshot field to
avoid migrating tenant data. Replace the free-form Instructions textarea with
a file-upload control and download link. Keep the database representation as
text; enforce a single UTF-8 `.md` file, exact submitted basename
`instructions.md`, and the existing 32,000-byte limit both in the UI and domain
validation. Read server-side uploaded bytes and reject invalid UTF-8 or empty
content with a visible field error. A failed upload or save must leave the
previously saved project instructions unchanged.

Include an upload on project creation and project settings. Require valid
instructions to create a project. On existing projects, replacement upload is
optional when saving other rules; owners can add or replace the file later.
Existing projects without saved instructions remain executable and do not
receive a generated internal file until an owner uploads one. Do not log
contents or expose them in public project, event, executor or API responses
except the authenticated immutable task snapshot needed by its bound executor.

Before starting the coding agent, the connector writes the snapshotted text to
the task checkout's private `.git` metadata directory under the internal name
`WORKFLOW.md`, with restrictive permissions. The agent prompt explicitly
requires reading it. This avoids overwriting a repository-owned file of the
same name and keeps these instructions out of Git publication. If the task's
Git metadata cannot safely hold the file, fail that task before agent startup
and report a local setup blocker. Existing instructions are bound to the task
snapshot so a later project edit affects future runs only.

## Acceptance criteria

- New project setup requires an uploaded `instructions.md` and provides a
  downloadable, editable template.
- Project settings can replace the file and show a clear success or validation
  error without losing the previous saved version.
- Wrong basename, extension, encoding, empty content or content over 32,000
  bytes is rejected without creating or changing a project.
- A dispatched task carries an immutable copy of its project's instructions.
- The connector creates the internal `WORKFLOW.md` for the isolated task and
  the coding agent reads it before implementation.
- The file is not added to the source checkout, task diff, commit or pull
  request, and a pre-existing repository `WORKFLOW.md` is preserved.
- The downloadable file and customer UI do not mention any orchestration
  vendor, product, or internal filename.
- Tests cover upload validation, transactional preservation on failure,
  snapshot isolation, and task-file generation and non-publication.

## Review note

The current app stores project guidance as text in `projects.instructions` and
includes it in each task snapshot. This design preserves those stable storage
boundaries while changing the user-facing input to a file and placing the
internal copy under Git metadata, where it cannot be committed with task work.
