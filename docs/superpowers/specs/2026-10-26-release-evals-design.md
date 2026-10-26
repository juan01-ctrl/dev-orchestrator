# Pre-release reliability evaluations

## Intent

Catch regressions before releases, and produce evidence that distinguishes code
contracts, actual model behavior, and deployed integrations. The user authorized
implementation and one bounded live cycle on their test account's only project.

## Approach

Reuse the native ExUnit/Node suites as deterministic workflow evaluations rather
than duplicate their assertions. A versioned manifest maps stable scenario IDs to
real tests. Run repeated trials with varied seeds, collect machine-readable
per-test outcomes, and fail closed on missing, skipped, duplicate or failed cases,
process failures and timeouts. Run all native tests, not only mapped scenarios.

Add a fixed intake corpus with independent, field-specific acceptance checks,
negative controls and an opt-in adapter using the actual OpenAI implementation.
This is a narrow intent-preservation benchmark, not a universal semantic judge.
It cannot establish implementation quality or image fidelity.

Live smoke evidence remains separate. Exercise scoped Slack text/audio,
confirmation/correction, Linear intake, execution, verified PR delivery and
same-PR continuation where accessible. Grade actual final state, not agent prose.
Unreachable providers, missing credentials, absent evidence and unperformed checks
are blocked/not-run, never passes. Report bounded repetitions, not a production
reliability percentage.

## Constraints and safety

- No new production evaluator agent, framework, dependency or model configuration.
  A narrowly scoped lifecycle fix discovered by the authorized cycle is included
  locally, with a regression that fails before the fix; deployment remains manual.
- No raw provider credentials, transcripts, prompts or subprocess logs in reports.
- Default commands make no external provider calls. Live model calls need an
  explicit flag and existing credentials; the configured model is recorded.
- Retain existing source checkout and unrelated edits; no automatic commit/push,
  npm publication, deployment, merge, credential change or executor shutdown.
- Live changes are isolated evaluation files in the authorized test repository,
  clearly marked tasks/PRs, left open and listed in the final report.
- Avoid disrupting live work to test recovery; inject failures only in local
  fixtures, and label those results accordingly.

## Grading and artifacts

Store ignored private JSON reports under `.runtime/evals/`, with code revision,
dirty flag, manifest/corpus hashes, seed, duration, per-scenario outcomes and
category summaries. Exit nonzero on any regression. Model/live checks are not
silently included in the deterministic pass rate. No automatic claim of release
readiness from a green local suite. CI runs the deterministic runner and uploads
only sanitized reports. Live model work is capped by cases/trials and timeouts.

## Alternatives

A hosted evaluation platform adds setup and data export before it adds value.
An LLM judging every run adds costs and another uncalibrated failure source.
Neither is necessary for the requested pre-release gate. Native suites plus a
small explicit runner and independent corpus are the chosen implementation.

## Known boundaries

Lexical fact checks can detect omitted literal requirements but cannot certify
arbitrary semantic equivalence. Model graders are not introduced until calibrated
human examples justify them. Live outages are recorded, not worked around by
weakening authentication or fabricating webhook signatures.
