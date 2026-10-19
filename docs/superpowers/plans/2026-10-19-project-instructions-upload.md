# Project Instructions Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require a project owner to upload `instructions.md` when creating a project, offer a downloadable template, and make the saved guidance available to every local task under an internal filename without publishing it.

**Architecture:** Keep project guidance in the existing `projects.instructions` column and immutable run snapshot. Phoenix LiveView accepts one validated Markdown upload and serves a generic template; the local connector writes each task snapshot as `.git/WORKFLOW.md` in its isolated clone and explicitly asks Codex to read it.

**Tech Stack:** Elixir 1.19, Phoenix LiveView 1.2, Ecto/PostgreSQL, TypeScript/Node.js.

**Spec:** `docs/superpowers/specs/2026-10-19-project-instructions-upload-design.md`.

## Global Constraints

- Customer-facing UI and downloadable template refer to the file only as `instructions.md`.
- Template and UI contain no vendor, orchestration product, or internal filename references.
- Accept exactly one non-empty UTF-8 Markdown file named `instructions.md`, up to 32,000 bytes.
- Preserve current `projects.instructions` persistence and per-run snapshot semantics; no schema migration.
- Existing projects with saved or empty instructions remain readable; a replacement upload is optional when editing an existing project.
- Legacy projects without saved instructions remain executable with their current behavior until an owner uploads a file; the connector skips internal file generation for an empty snapshot.
- Generated `.git/WORKFLOW.md` is private task metadata and must never enter the task's Git diff, commit, or PR.
- Preserve any root-level repository `WORKFLOW.md`; the generated file lives only under the isolated clone's `.git` directory.
- Do not change the separate Symphony installation or its configuration.

## Review Focus

- Spoofed upload basename: reject server-side unless it is exactly `instructions.md`.
- Invalid UTF-8, empty content, or content over 32,000 bytes: show a validation error and do not create/update the project.
- Failed replacement upload: retain the previously stored instructions.
- Retry or later project edit: active run snapshot stays unchanged and subsequent runs get current instructions.
- Repository already contains a root `WORKFLOW.md`: preserve it while generating private task metadata outside Git's tracked tree.

---

### Task 1: Ship the downloadable generic template

**Files:**
- Create: `platform/priv/static/templates/instructions.md`
- Modify: `platform/lib/dev_orchestrator_web/endpoint.ex`
- Test: `platform/test/dev_orchestrator_web/assets_test.exs`

**Interfaces:**
- Browser path: `GET /templates/instructions.md`, downloaded with filename `instructions.md`.
- Template sections: project context, repository guidance, implementation, validation, Git/delivery, completion report.

- [ ] **Step 1: Write a failing static delivery test** asserting `GET /templates/instructions.md` returns status 200 and the generic Markdown template body.
- [ ] **Step 2: Run the focused test** with `cd platform && mise exec -- mix test test/dev_orchestrator_web/assets_test.exs`; confirm it fails because the template path is not served.
- [ ] **Step 3: Add the template and static route** by serving only the templates directory needed for this file and setting the link's suggested download name to `instructions.md`. Keep vendor and internal names out of template content.
- [ ] **Step 4: Run the focused test** and verify the response is downloadable, non-empty Markdown with the expected generic headings.
- [ ] **Step 5: Commit** as `feat(ui): add project instructions template`.

### Task 2: Require and validate uploads in project flows

**Files:**
- Modify: `platform/lib/dev_orchestrator/projects.ex`
- Modify: `platform/lib/dev_orchestrator_web/live/dashboard_live.ex`
- Test: `platform/test/dev_orchestrator/projects_test.exs`
- Test: `platform/test/dev_orchestrator/runs_test.exs`
- Test: `platform/test/dev_orchestrator_web/live/project_live_test.exs`

**Interfaces:**
- Add `Projects.validate_instructions(filename, bytes) :: {:ok, text} | {:error, reason}`. It accepts exact filename `instructions.md`, valid UTF-8 non-empty content, and no more than 32,000 bytes.
- New project LiveView upload is required; project rules upload is optional and replaces the current text only after successful validation and save.
- Keep database and snapshot field named `instructions`; do not expose the internal filename in form copy or errors.

- [ ] **Step 1: Write failing domain tests** for accepted UTF-8 Markdown and rejected basename, extension, invalid UTF-8, blank body, and 32,001-byte body.
- [ ] **Step 2: Run the focused domain test** and verify the new validation function/branches fail as expected.
- [ ] **Step 3: Implement `Projects.validate_instructions/2`** and use it before `create_project/2` or `update_project/3` can persist uploaded text.
- [ ] **Step 4: Write failing run snapshot tests** proving claims include uploaded instructions, an active lease keeps its old snapshot after editing, and a later task receives the updated text.
- [ ] **Step 5: Run the focused run test** and verify project text is not yet asserted as immutable per lease.
- [ ] **Step 6: Write failing LiveView tests** for required creation upload, template link, successful project creation with uploaded content, successful replacement, and failed replacement preserving saved instructions.
- [ ] **Step 7: Run the focused LiveView test** and verify the form currently lacks upload and replacement behavior.
- [ ] **Step 8: Add a one-entry LiveView upload** with server-side validation; consume uploaded bytes before invoking project persistence. Show field-level errors and leave the existing record unchanged on error. Include upload controls and template link in both New project and Project rules.
- [ ] **Step 9: Run the focused domain, run and LiveView test files** and verify validation, persistence, snapshot and UI behavior.
- [ ] **Step 10: Run `cd platform && mise exec -- mix test`** and confirm the full platform suite passes.
- [ ] **Step 11: Commit** as `feat(projects): upload project instructions`.

### Task 3: Materialize the immutable snapshot inside each task checkout

**Files:**
- Modify: `connector/src/workspace.ts`
- Modify: `connector/src/worker.ts`
- Test: `connector/test/workspace.test.ts`
- Test: `connector/test/worker.test.ts`

**Interfaces:**
- Add `writeProjectInstructions(workspace: string, instructions: unknown): Promise<string | undefined>`; require a string no larger than 32,000 bytes, return `undefined` for the empty legacy value, verify the checkout's `.git` metadata directory is a real directory, and write non-empty content to `.git/WORKFLOW.md` with mode `0600`.
- Worker calls this with `lease.snapshot.instructions` after workspace preparation and before starting Codex; when a path is returned, the prompt instructs Codex to read it. Empty legacy snapshots follow the current prompt behavior.

- [ ] **Step 1: Write a failing connector test** for writing exact snapshot bytes under `.git/WORKFLOW.md`, restrictive permissions, preserving root `WORKFLOW.md`, skipping an empty legacy snapshot, rejecting non-string/oversized instructions, and leaving `git status --porcelain` clean.
- [ ] **Step 2: Run the focused connector test** with `cd connector && npm test -- --test-name-pattern="project instructions"`; verify the helper is absent or incomplete.
- [ ] **Step 3: Implement `writeProjectInstructions`** with strict type/size checks and no writes outside the isolated clone's `.git` metadata directory.
- [ ] **Step 4: Add a worker-level test** proving a non-empty snapshot is written before the coding session starts and the prompt directs the agent to read that path, while an empty legacy snapshot keeps the existing prompt behavior.
- [ ] **Step 5: Run the focused connector tests**, then `cd connector && npm test` and `cd connector && npm run check`.
- [ ] **Step 6: Commit** as `feat(connector): load project instructions per task`.

### Task 4: Document owner setup and verify both sides together

**Files:**
- Modify: `README.md`
- Modify: `docs/protocol.md`

**Interfaces:**
- Explain where project owners download and upload `instructions.md`, what is validated, how edits affect future tasks, and how to troubleshoot a missing file.
- Document that the connector consumes the immutable `instructions` snapshot without exposing its internal on-disk name in customer-facing guidance.

- [ ] **Step 1: Update setup documentation** with the file/template workflow and upload constraints, using customer-facing terms only.
- [ ] **Step 2: Review the final diff** to ensure no template attribution or internal filename appears in customer-facing docs or UI.
- [ ] **Step 3: Run platform tests, connector tests/check, and `git diff --check`**; record any environment blocker with its exact cause.
- [ ] **Step 4: Commit** as `docs: explain project instruction files`.
