# Linear Task Assets Specification

## Goal

Allow an executor to use images, CSV files, PDFs, text files, and common office documents uploaded to a Linear issue description without exposing Linear credentials or permitting arbitrary network access.

## Scope

- Discover Linear-hosted files referenced by Markdown links and images in the issue description.
- Materialize accepted files inside the isolated task workspace before Codex starts.
- Give Codex local paths and explicitly identify the files as untrusted reference material.
- Preserve deterministic retry and recovery behavior.
- Report unavailable or rejected files without silently pretending that full context was available.

Linear `Attachment` entities are external integration links, not uploaded file storage, and remain URL-only. Comment attachments and arbitrary external URLs are outside this first release.

## Requirements

- Only exact `https://uploads.linear.app/...` URLs may be fetched.
- Linear OAuth credentials remain in the cloud control plane and never appear in leases, logs, events, prompts, or connector configuration.
- Every download must be authorized against the authenticated executor, active lease generation, organization, project, source Linear connection, and asset ID.
- Limits: at most 10 files, 10 MiB per file, and 25 MiB total per run.
- Accept PNG, JPEG, GIF, WebP, CSV, TSV, plain text, Markdown, JSON, YAML, XML, PDF, DOCX, and XLSX. Reject HTML, SVG, archives, executables, macro-enabled office files, and unknown binary content.
- Do not follow redirects. Enforce size while reading the response, not only from `Content-Length`.
- Sanitize filenames, prevent traversal and symlink replacement, and exclude the context directory from Git publication.
- A failed optional download must not crash or repeatedly restart the run. It must be visible to Codex and in execution activity. Codex may return `missing_context` only when the unavailable file is indispensable.
- Asset bytes and private source URLs must not be persisted in logs, events, public snapshots, or run results.

## Success Criteria

- A Linear issue description containing a PNG and CSV results in two readable local files before the first agent turn.
- The prompt includes their local paths and the agent can inspect both.
- Cross-tenant, stale-lease, unsupported-type, oversized, redirected, and path-traversal requests are rejected safely.
- Restarting the connector reuses already verified files and does not duplicate downloads or agent work.
- Runtime context files never appear in the produced commit or pull request.
