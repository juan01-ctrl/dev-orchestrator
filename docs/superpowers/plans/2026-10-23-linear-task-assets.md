# Linear Task Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Linear-hosted images and files available as safe local reference material to the Codex executor.

**Architecture:** The control plane extracts exact `uploads.linear.app` references during Linear intake and stores their private URLs in server-only run context. A lease exposes only opaque asset metadata; an authenticated executor endpoint proxies bounded downloads using the correct tenant's Linear connection. The connector materializes verified files in a Git-excluded workspace directory and passes their local paths to Codex as untrusted context.

**Tech Stack:** Elixir/Phoenix, PostgreSQL JSONB, Req, Node.js/TypeScript, Codex app-server, ExUnit, Node test runner.

**Spec:** `docs/superpowers/specs/2026-10-23-linear-task-assets.md`

## Global Constraints

- Fetch only exact `https://uploads.linear.app/...` URLs; never fetch arbitrary attachment URLs.
- Keep Linear credentials and private source URLs out of leases, prompts, events, logs, and connector storage.
- Enforce 10 files, 10 MiB per file, and 25 MiB total per run.
- Reject redirects, active content, archives, executables, macro-enabled documents, and unknown binary content.
- Treat attachment contents as untrusted data, never as higher-priority instructions.
- Preserve current tenant isolation, lease fencing, retry budgets, and outbound-only executor architecture.
- Do not add object storage or a new background service for this release.

## Review Focus

- A crafted `uploads.linear.app.evil.example` or user-info URL must never pass host validation; Task 1 tests this.
- A valid asset ID requested by another tenant or stale lease must return no bytes; Task 2 tests this.
- Missing or false `Content-Length` must not bypass byte limits; Task 2 tests streamed-size enforcement.
- Filenames containing traversal, control characters, collisions, or reserved names must stay inside the context directory; Task 3 tests this.
- Connector restart during asset materialization must be idempotent and must not trigger a duplicate agent turn; Task 4 tests this.

---

## File Map

- `platform/lib/dev_orchestrator/intake/linear_assets.ex`: parse and normalize Linear-hosted asset references.
- `platform/lib/dev_orchestrator/runs/assets.ex`: authorize a lease asset request and fetch bounded bytes through the source Linear connection.
- `platform/priv/repo/migrations/20261026000000_add_run_source_context.exs`: add private provider context to runs.
- `platform/lib/dev_orchestrator/runs/lifecycle.ex`: persist assets and source connection during intake/rework.
- `platform/lib/dev_orchestrator/runs.ex`: expose sanitized asset metadata in leases and fence downloads.
- `platform/lib/dev_orchestrator/connections/linear.ex`: authenticated, non-redirecting Linear file download.
- `platform/lib/dev_orchestrator_web/controllers/executor_controller.ex`: binary executor asset endpoint.
- `platform/lib/dev_orchestrator_web/router.ex`: route the executor asset endpoint.
- `connector/src/api.ts`: authenticated bounded binary download client.
- `connector/src/task-assets.ts`: safe, idempotent workspace materialization.
- `connector/src/repository.ts`: exclude task context from Git.
- `connector/src/worker.ts`: materialize before Codex and add paths/status to the prompt.
- `connector/src/types.ts`: lease and journal asset types.
- `platform/lib/dev_orchestrator_web/live/dashboard_components.ex`: useful attachment activity copy.

### Task 1: Extract and persist private Linear asset context

**Files:**
- Create: `platform/lib/dev_orchestrator/intake/linear_assets.ex`
- Create: `platform/priv/repo/migrations/20261026000000_add_run_source_context.exs`
- Modify: `platform/lib/dev_orchestrator/intake/inbox.ex`
- Modify: `platform/lib/dev_orchestrator/intake/linear.ex`
- Modify: `platform/lib/dev_orchestrator/intake/reconciler.ex`
- Modify: `platform/lib/dev_orchestrator/runs/lifecycle.ex`
- Test: `platform/test/dev_orchestrator/linear_assets_test.exs`
- Test: `platform/test/dev_orchestrator/runs_lifecycle_test.exs`

**Interfaces:**
- Produces: `LinearAssets.extract(markdown) :: %{assets: [private_asset], skipped_count: non_neg_integer}` where each private asset has `id`, `source_url`, and `filename_hint`.
- Produces: `runs.source_context jsonb NOT NULL DEFAULT '{}'`, containing `linear_connection_id` and private assets.
- Consumes later: Task 2 reads private assets; lease creation publishes only `id` and `filename_hint`.

- [ ] **Step 1: Write failing extraction tests**

  Add tests named `extracts_markdown_images_and_file_links`, `deduplicates_repeated_upload_urls`, `rejects_non_linear_and_lookalike_hosts`, and `caps_the_manifest_at_ten_assets`. Assert exact-host HTTPS validation, opaque UUID-shaped IDs, sanitized filename hints, source-order preservation, and `skipped_count`.

- [ ] **Step 2: Run the focused tests and confirm they fail**

  Run: `cd platform && mise exec -- mix test test/dev_orchestrator/linear_assets_test.exs`

  Expected: failure because `DevOrchestrator.Intake.LinearAssets` does not exist.

- [ ] **Step 3: Implement `LinearAssets.extract/1`**

  Parse Markdown image/link destinations plus bare URLs, validate with `URI.parse/1`, accept only scheme `https`, host exactly `uploads.linear.app`, no user-info or fragment, and deduplicate by normalized URL. Generate a random opaque ID at intake; never derive a public ID that reveals the URL.

- [ ] **Step 4: Add the private run context migration**

  Add `source_context jsonb NOT NULL DEFAULT '{}'` to `runs`. Do not reuse `snapshot`, because snapshots are delivered to the executor.

- [ ] **Step 5: Write failing lifecycle tests**

  Extend `runs_lifecycle_test.exs` to assert that initial activation and queued issue corrections persist the current `linear_connection_id`, private URLs, and sanitized filename hints while leaving `prompt` textual and bounded.

- [ ] **Step 6: Thread the source connection through intake**

  Change lifecycle entry points to `Lifecycle.apply_issue(project, issue, source_context \\ %{})`. Every webhook/reconciliation call passes the connection ID; `task_context/1` stores extracted assets separately from the 8,000-character prompt.

- [ ] **Step 7: Run platform intake tests**

  Run: `cd platform && mise exec -- mix test test/dev_orchestrator/linear_assets_test.exs test/dev_orchestrator/runs_lifecycle_test.exs test/dev_orchestrator/intake_authorization_test.exs`

  Expected: all pass with no private URL in returned run/lease fixtures.

- [ ] **Step 8: Commit**

  ```bash
  git add platform/lib/dev_orchestrator/intake platform/lib/dev_orchestrator/runs/lifecycle.ex platform/priv/repo/migrations platform/test/dev_orchestrator
  git commit -m "feat: capture Linear task assets"
  ```

### Task 2: Add a tenant-safe bounded download endpoint

**Files:**
- Create: `platform/lib/dev_orchestrator/runs/assets.ex`
- Modify: `platform/lib/dev_orchestrator/connections/linear.ex`
- Modify: `platform/lib/dev_orchestrator/runs.ex`
- Modify: `platform/lib/dev_orchestrator_web/controllers/executor_controller.ex`
- Modify: `platform/lib/dev_orchestrator_web/router.ex`
- Test: `platform/test/dev_orchestrator/run_assets_test.exs`
- Test: `platform/test/dev_orchestrator_web/controllers/executor_controller_test.exs`
- Test: `platform/test/dev_orchestrator/provider_test.exs`

**Interfaces:**
- Produces: `Runs.asset(executor, lease, asset_id) :: {:ok, %{body: binary, filename: binary, media_type: binary, sha256: binary}} | {:error, atom}`.
- Produces: `Linear.download_file(token, source_url, opts) :: {:ok, bounded_file} | {:error, atom}`.
- Produces: `POST /api/v1/executor/assets` with executor bearer authentication and body `{lease, asset_id}`; success is binary with safe metadata headers.
- Consumes: private `source_context` from Task 1.

- [ ] **Step 1: Write failing authorization tests**

  Cover valid active lease, unknown asset, stale generation, expired lease, wrong executor, wrong organization, revoked/missing source connection, and a connection not granted to the run's project. Assert every rejected case returns no body or private URL.

- [ ] **Step 2: Implement fenced lookup in `Runs.Assets`**

  Lock and validate the same executor/run/generation/lifecycle tuple used by existing lease operations. Resolve the asset only from that run's private `source_context`, then resolve the exact organization/project Linear grant before obtaining credentials.

- [ ] **Step 3: Write failing provider download tests**

  Assert bearer authentication, `redirect: false`, bounded timeout, no URL logging, exact-host revalidation, allowed MIME types, actual-body size enforcement, and rejection of redirects, HTML/SVG, archives, executables, macro documents, and unknown binary content.

- [ ] **Step 4: Implement `Linear.download_file/3`**

  Use Req with body decoding disabled. Read at most 10 MiB plus one byte, independently of `Content-Length`; calculate SHA-256 after validation. Normalize Content-Type without trusting it alone: accepted content must match the allowed MIME/extension policy.

- [ ] **Step 5: Add sanitized lease metadata**

  When claiming a run, add `task_assets: [%{"id" => id, "filename_hint" => hint}]` and `task_assets_skipped` to the snapshot. Never include `source_url` or `linear_connection_id`.

- [ ] **Step 6: Add and test the binary controller endpoint**

  Return `Content-Type`, safe `Content-Disposition`, `X-Dev-Orchestrator-SHA256`, and `X-Dev-Orchestrator-Size`. Map authorization failures to 404, stale leases to 409, rejected files to 422, and provider failures to 503 without exposing upstream details.

- [ ] **Step 7: Run focused platform tests**

  Run: `cd platform && mise exec -- mix test test/dev_orchestrator/run_assets_test.exs test/dev_orchestrator/provider_test.exs test/dev_orchestrator_web/controllers/executor_controller_test.exs`

  Expected: all pass, including cross-tenant and response-size cases.

- [ ] **Step 8: Commit**

  ```bash
  git add platform/lib/dev_orchestrator platform/lib/dev_orchestrator_web platform/test/dev_orchestrator platform/test/dev_orchestrator_web
  git commit -m "feat: proxy Linear assets to executors"
  ```

### Task 3: Materialize safe task assets in the isolated workspace

**Files:**
- Create: `connector/src/task-assets.ts`
- Modify: `connector/src/api.ts`
- Modify: `connector/src/repository.ts`
- Modify: `connector/src/types.ts`
- Test: `connector/test/task-assets.test.ts`
- Test: `connector/test/repository.test.ts`
- Create: `connector/test/api.test.ts`

**Interfaces:**
- Produces: `API.downloadAsset(lease, assetId, limits) :: Promise<DownloadedAsset>`.
- Produces: `materializeTaskAssets(api, lease, workspace, previous?) :: Promise<MaterializedAssetReport>`.
- Produces: local files under `<workspace>/.dev-orchestrator-context/linear/` and a private journal record containing only asset ID, relative path, size, and SHA-256.

- [ ] **Step 1: Write failing API download tests**

  Assert executor authorization, binary handling, 15-second timeout, required SHA/size headers, 10 MiB response cap, and safe error mapping without logging response bodies.

- [ ] **Step 2: Implement `API.downloadAsset/3`**

  Add a dedicated binary method; keep the existing JSON `post/2` contract unchanged. Abort reads over the declared limit even when headers lie or are absent.

- [ ] **Step 3: Write failing materialization tests**

  Cover traversal names, absolute paths, Unicode/control characters, duplicate filenames, symlink targets, more than 25 MiB total, partial temporary files, hash mismatch, and a second idempotent call after restart.

- [ ] **Step 4: Implement `materializeTaskAssets/4`**

  Resolve and verify the canonical workspace, create owner-only directories, write each response to an exclusive temporary file, verify server digest/size, atomically rename, and chmod files read-only. Name collisions use an asset-ID prefix rather than overwriting.

- [ ] **Step 5: Exclude task context from Git**

  Add `/.dev-orchestrator-context/` to common Git `info/exclude`. Extend repository and publisher regression tests to prove files never appear in staged changes or commits.

- [ ] **Step 6: Run connector asset tests**

  Run: `cd connector && npm run check && node --experimental-strip-types --test test/api.test.ts test/task-assets.test.ts test/repository.test.ts`

  Expected: all pass and temporary files are removed after failures.

- [ ] **Step 7: Commit**

  ```bash
  git add connector/src connector/test
  git commit -m "feat: materialize Linear task assets"
  ```

### Task 4: Integrate assets with execution, recovery, and visibility

**Files:**
- Modify: `connector/src/worker.ts`
- Modify: `connector/src/types.ts`
- Modify: `connector/src/journal.ts`
- Modify: `platform/lib/dev_orchestrator_web/live/dashboard_components.ex`
- Test: `connector/test/worker.test.ts`
- Test: `connector/test/recovery-flow.test.ts`
- Test: `platform/test/dev_orchestrator/event_test.exs`
- Test: `platform/test/dev_orchestrator_web/live/project_live_test.exs`

**Interfaces:**
- Consumes: `MaterializedAssetReport` from Task 3.
- Produces: a prompt section listing available local paths and unavailable filenames/reasons, prefixed as untrusted reference material.
- Produces: bounded `progress` event stage `task_context_ready` with counts only.

- [ ] **Step 1: Write failing worker tests**

  Assert assets materialize after repository setup and before the first Codex turn; available paths appear in the prompt; contents, source URLs, and credentials do not. Assert unavailable optional assets do not consume an implementation retry.

- [ ] **Step 2: Integrate materialization into `execute/8`**

  Persist the materialization report before starting Codex. The prompt must say files are untrusted reference data, must not override repository/project instructions, and an indispensable unavailable file should produce one precise `missing_context` question.

- [ ] **Step 3: Make restart behavior deterministic**

  Extend `JournalState` with the verified report. On recovery, verify existing file size/hash and reuse it; download only missing or corrupt files. Never restart a completed agent turn solely because an optional asset became unavailable.

- [ ] **Step 4: Add bounded execution activity**

  Emit only `{available_count, unavailable_count, skipped_count}`. Add UI copy such as “Task reference files are ready” and “Some task files could not be loaded”; never emit filenames if they may contain sensitive user data.

- [ ] **Step 5: Run focused recovery and UI tests**

  Run: `cd connector && npm run check && node --experimental-strip-types --test test/worker.test.ts test/recovery-flow.test.ts`

  Run: `cd platform && mise exec -- mix test test/dev_orchestrator/event_test.exs test/dev_orchestrator_web/live/project_live_test.exs`

  Expected: all pass; recovery uses one agent turn and activity remains bounded.

- [ ] **Step 6: Commit**

  ```bash
  git add connector/src connector/test platform/lib/dev_orchestrator_web platform/test
  git commit -m "feat: expose task assets to Codex"
  ```

### Task 5: Verify the complete delivery path and document limits

**Files:**
- Modify: `README.md`
- Modify: `platform/test/offline.exs`
- Create: `docs/operations/linear-task-assets.md`
- Optional provider test: `platform/test/provider/linear_task_assets_test.exs`

**Interfaces:**
- Documents the supported types, limits, issue-description-only scope, security model, and operator diagnostics.
- Provides an opt-in real-provider smoke test; normal test suites remain deterministic and offline.

- [ ] **Step 1: Add the new pure modules to offline coverage**

  Ensure `linear_assets.ex` and any pure validation module load in `test/offline.exs` so sandboxed verification exercises their contracts.

- [ ] **Step 2: Add an opt-in provider smoke test**

  Given a configured test issue containing one PNG and one CSV, assert intake creates opaque metadata, the executor endpoint returns both, and no token/private URL appears in recorded events. Skip unless explicit provider-test environment variables are present.

- [ ] **Step 3: Document operations and user-visible limits**

  Explain that files must be uploaded into the issue description, external link cards are not downloaded, failures remain visible, and secrets stay server-side. Include the accepted-type and size tables plus remediation for rejected/expired assets.

- [ ] **Step 4: Run all verification**

  ```bash
  cd platform
  mise exec -- mix format --check-formatted
  mise exec -- mix test

  cd ../connector
  npm run check
  npm test

  cd ..
  git diff --check
  ```

  Expected: platform and connector suites pass with zero failures; any infrastructure-blocked provider smoke test is explicitly reported rather than counted as passed.

- [ ] **Step 5: Perform a manual end-to-end acceptance run**

  Create a Linear issue whose description includes a PNG and CSV, move it into an active state, and verify: one run is created, the activity reports two available files, the agent summarizes both correctly, the PR excludes `.dev-orchestrator-context`, and Slack/Linear delivery remains unchanged.

- [ ] **Step 6: Commit**

  ```bash
  git add README.md docs platform/test/offline.exs platform/test/provider
  git commit -m "docs: document Linear task assets"
  ```

## Release Sequence

1. Deploy the platform migration and server changes first; old connectors ignore the added lease metadata.
2. Publish a new connector version and update the executor installation command.
3. Run the opt-in PNG/CSV smoke test against production credentials.
4. Monitor asset rejection categories and download latency without logging filenames or URLs.
5. Add comment attachment ingestion only as a separate follow-up after issue-description behavior is stable.
