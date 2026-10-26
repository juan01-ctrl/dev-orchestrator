# Independent candidate review and human PR context

## Outcome

Every fresh workflow-v2 implementation candidate receives one independent review
before it is pushed. The reviewer gets a fresh Codex process/thread and a private
Git clone pinned to the candidate and original baseline, not the implementation
checkout, conversation, caches or self-review. PR descriptions and subsequent
update comments give humans the original request, scope, files, validation,
independent findings, limitations and exact reviewed commit.

## Decisions

- Reuse the installed Codex app-server with a dedicated read-only permission
  profile and no tool network access. The reviewer gets no publication credential.
  A clean clone alone is not a security sandbox; the permission profile is the
  runtime boundary. Use the already selected immutable task model, never silently
  change models or global configuration.
- Use a trusted temporary bare repository to export the candidate and baseline,
  with hooks, external filters, replace objects and global Git config disabled.
  Review clone has its own object store/index and no remote or alternates. Copy
  only separately reverified task-reference assets, never implementation runtime
  notes. Provide frozen project instructions separately as task context.
- Give the reviewer original title/request, original baseline, pinned head,
  approved adjustment if present and references. Do not send implementation
  summary, transcript, test claims or self-review. Repository content is untrusted
  evidence, not authority to override review instructions.
- Review is inspection-only in v1; no dependency installation, full build reruns
  or writable source checkout. Existing deterministic checks remain mandatory and
  independent. State this limitation explicitly, rather than suggesting tests ran.
- A strict structured verdict cites paths/lines/evidence. Critical/important
  findings block publication. Malformed, timed-out or inconclusive review blocks
  too; minor findings are disclosed. No automatic review-fix loop in this change.
- Preserve local review provenance (base, head, generation) in the private journal.
  Reuse only for the identical commit/base/generation on publication retry; a new
  continuation or changed head must be independently reviewed again. Legacy
  snapshots keep legacy behavior; fresh server snapshots opt into review v1.
- Commit locally before review; never request a publish token until review passes.
  Recheck clean status/head immediately before push. Stop implementation process
  before creating reviewer. Bound review to three minutes within task deadline.
- Expand PR body with trusted task context and file list, clearly labeled agent
  summary, actual recorded check statuses, reviewer findings/limitations and human
  review checklist. Do not claim visual fidelity or full correctness. Redact
  secrets, local paths and private provider asset URLs; escape task-derived Markdown.
- For existing PRs, add a detailed, commit-marked summary comment using existing
  publication permissions; do not overwrite a human's PR description. Find an
  existing exact marker/author before posting, and never blindly repeat an
  ambiguous comment write. Preserve candidate verification and no-force-push fences.

## Scope and tradeoffs

No new framework, external service, provider permission, model override or merge
automation. A fresh model context plus separate read-only copy improves independence
but does not guarantee an unbiased/infallible reviewer. Blocking adds bounded
latency and model usage. No live provider calls, publication or deployment during
source implementation. Connector release and server deploy remain owner actions.

## Alternatives considered

A worktree with shared Git metadata is cheaper but insufficient clean-room
separation. A new cloud/container runtime adds deployment and credential surfaces
without being necessary for the existing local permission boundary. A fresh clone
plus existing read-only app-server is the selected bounded implementation.
