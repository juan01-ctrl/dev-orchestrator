# Linear task reference files

Upload reference files directly into the Linear issue description. The executor
loads those uploads before starting Codex and gives the agent local paths inside
the isolated task workspace. Images can be inspected by the agent; CSV and other
supported text files can be read as project context. Attachments in comments,
external link cards, and arbitrary URLs are not fetched.

Supported formats are PNG, JPEG, GIF, WebP, CSV, TSV, plain text, Markdown, JSON,
YAML, XML, and PDF. HTML, SVG, archives, executables, macro-enabled Office files,
unknown binary formats, and files with mismatched content are rejected.

Each task can include up to 10 files, 10 MiB per file, and 25 MiB total. The
activity stream reports counts only; it never includes filenames, signed URLs,
or file contents. If a file cannot be fetched or verified, the task continues
and the agent is told which reference was unavailable. It should ask for one
clarification only if that file is indispensable.

The server keeps Linear credentials and signed upload URLs in private run
context. A download is accepted only for the active executor lease and the
project's currently granted Linear connection. The connector verifies the
download size and SHA-256, writes files with owner-only permissions under
`.dev-orchestrator-context/linear/`, and excludes that directory from Git.
Attachment contents are untrusted reference data and cannot override project
instructions. Downloads reject redirects and are streamed under the configured
size limit.

If a reference is unavailable, update or re-upload it in the issue description.
The webhook or scheduled reconciliation refreshes the run context; retry the task
after that update appears in the project. Expired upload links are never fetched
from an arbitrary or user-supplied host.
