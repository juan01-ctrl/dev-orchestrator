import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { assessIntake, validateCorpus } from './grade.mjs';
import { runProcess } from './core.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2);
let trials = 1, selected = null;
if (!args.includes('--live')) {
  console.error('Explicit opt-in required: node evals/intake.mjs --live [--trials 1..3] [--case ID]');
  process.exit(2);
}
const remaining = args.filter(a => a !== '--live');
for (let i = 0; i < remaining.length; i += 2) {
  if (remaining[i] === '--trials' && /^[1-3]$/.test(remaining[i + 1] ?? '')) trials = Number(remaining[i + 1]);
  else if (remaining[i] === '--case' && /^[a-z][a-z0-9_.-]+$/.test(remaining[i + 1] ?? '')) selected = remaining[i + 1];
  else { console.error('Invalid eval options'); process.exit(2); }
}
const bytes = await readFile(new URL('./intake-cases.json', import.meta.url));
const corpus = validateCorpus(JSON.parse(bytes));
const cases = corpus.cases.filter(c => selected === null || c.id === selected);
if (!cases.length) { console.error('Unknown eval case'); process.exit(2); }
const sha = await runProcess('git', ['rev-parse', 'HEAD'], { cwd: root });
const dirty = await runProcess('git', ['status', '--porcelain'], { cwd: root });
const report = {
  schema_version: 1, kind: 'live_intake_model', started_at: new Date().toISOString(),
  revision: sha.code === 0 ? sha.stdout.trim() : null, dirty: dirty.code !== 0 || !!dirty.stdout.trim(),
  corpus_sha256: createHash('sha256').update(bytes).digest('hex'), model: null,
  passed: false, release_ready: false, trials: [],
  limitations: ['Literal fact/constraint checks, not a general semantic judge.', 'Transcript cases do not measure audio decoding.', 'No implementation or deployed workflow validation.']
};
const output = path.join(root, '.runtime/evals', report.started_at.replace(/[:.]/g, '-'));
await mkdir(output, { recursive: true, mode: 0o700 });
const save = () => writeFile(path.join(output, 'intake.json'), JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
await save();
for (let trial = 1; trial <= trials; trial++) {
  console.log(`Live model trial ${trial}/${trials}: ${cases.length} cases, maximum 45 seconds per case.`);
  const result = await runProcess('mix', ['run', '--no-start', '../evals/intake.exs'], {
    cwd: path.join(root, 'platform'), timeoutMs: cases.length * 46_000 + 30_000,
    env: { DEV_ORCHESTRATOR_EVAL_LIVE: '1', ...(selected ? { DEV_ORCHESTRATOR_EVAL_CASE: selected } : {}) }
  });
  const assessed = assessIntake(cases, result.stdout, result.code);
  report.model = assessed.model;
  report.trials.push({ trial, duration_ms: result.duration_ms, passed: assessed.passed, cases: assessed.cases });
  await save();
  if (assessed.blocked || result.reason) break; // Never multiply a known configuration/outage failure.
}
report.passed = report.trials.length === trials && report.trials.every(t => t.passed);
report.finished_at = new Date().toISOString();
await save();
console.log(`${report.passed ? 'PASS' : 'FAIL/BLOCKED'}: live intake model gate. Report: ${path.relative(root, path.join(output, 'intake.json'))}`);
process.exitCode = report.passed ? 0 : 1;
