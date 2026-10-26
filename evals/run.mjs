import { readFile, mkdir, writeFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { assess, parseRecords, runProcess, validateManifest } from './core.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2);
let trials = 3;
if (args.length) {
  if (args.length !== 2 || args[0] !== '--trials' || !/^[1-5]$/.test(args[1])) {
    console.error('Usage: node evals/run.mjs [--trials 1..5]'); process.exit(2);
  }
  trials = Number(args[1]);
}
const manifestBytes = await readFile(new URL('./manifest.json', import.meta.url));
const manifest = validateManifest(JSON.parse(manifestBytes));
const sha = await runProcess('git', ['rev-parse', 'HEAD'], { cwd: root });
const dirty = await runProcess('git', ['status', '--porcelain'], { cwd: root });
const report = {
  schema_version: 1, kind: 'deterministic_regression', started_at: new Date().toISOString(),
  revision: sha.code === 0 ? sha.stdout.trim() : null, dirty: dirty.code !== 0 || !!dirty.stdout.trim(),
  manifest_sha256: createHash('sha256').update(manifestBytes).digest('hex'),
  trials: [], passed: false, release_ready: false,
  limitations: ['Provider boundaries and agent responses are test doubles.', 'Model quality and deployed integration checks are separate gates.']
};
const output = path.join(root, '.runtime', 'evals', report.started_at.replace(/[:.]/g, '-'));
await mkdir(output, { recursive: true, mode: 0o700 });
const save = () => writeFile(path.join(output, 'regression.json'), JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
await save();

async function check(command, commandArgs, cwd, timeoutMs = 180_000) {
  const result = await runProcess(command, commandArgs, { cwd, timeoutMs });
  return { passed: result.code === 0, duration_ms: result.duration_ms, reason: result.reason ?? (result.code === 0 ? null : 'command_failed') };
}
console.log('Checking the eval harness, connector types and build...');
const testFiles = (await readdir(path.join(root, 'evals/test'))).filter(f => f.endsWith('.test.mjs')).sort().map(f => path.join(root, 'evals/test', f));
report.preflight = {
  harness: await check(process.execPath, ['--test', ...testFiles], root),
  typecheck: await check('npm', ['run', 'check'], path.join(root, 'connector')),
  build: await check('npm', ['run', 'build'], path.join(root, 'connector'))
};
await save();
if (Object.values(report.preflight).every(item => item.passed)) {
  for (let trial = 1; trial <= trials; trial++) {
    const seed = 17011 + trial * 7919;
    console.log(`Trial ${trial}/${trials}, ExUnit seed ${seed}`);
    const results = {};
    for (const engine of ['platform', 'connector']) {
      const cwd = path.join(root, engine);
      const command = engine === 'platform' ? 'mix' : process.execPath;
      const files = engine === 'connector' ? [
        ...(await readdir(path.join(cwd, 'test'))).filter(f => f.endsWith('.test.ts')).sort().map(f => `test/${f}`),
        ...(await readdir(path.join(cwd, 'test/app-server'))).filter(f => f.endsWith('.test.ts')).sort().map(f => `test/app-server/${f}`)
      ] : [];
      const commandArgs = engine === 'platform' ? ['test', '--seed', String(seed), '--formatter', 'DevOrchestrator.EvalFormatter'] :
        ['--experimental-strip-types', '--test', '--test-reporter', path.join(root, 'evals/node-reporter.mjs'), ...files];
      const result = await runProcess(command, commandArgs, { cwd, timeoutMs: 180_000 });
      let records = [], reason = result.reason;
      try { records = parseRecords(result.stdout); } catch { reason = 'invalid_reporter_evidence'; }
      results[engine] = { ...assess(manifest.scenarios.filter(s => s.engine === engine), records, reason ? 1 : result.code), reason, duration_ms: result.duration_ms };
      console.log(`  ${engine}: ${results[engine].passed ? 'PASS' : 'FAIL'} (${records.length} tests)`);
    }
    report.trials.push({ trial, seed, engines: results });
    await save();
  }
}
report.finished_at = new Date().toISOString();
report.passed = Object.values(report.preflight).every(item => item.passed) && report.trials.length === trials &&
  report.trials.every(t => Object.values(t.engines).every(item => item.passed));
report.summary = manifest.scenarios.map(s => {
  const outcomes = report.trials.map(t => t.engines[s.engine].scenarios.find(c => c.id === s.id)?.status ?? 'missing');
  return { id: s.id, category: s.category, passed_trials: outcomes.filter(o => o === 'passed').length, required_trials: trials, status: outcomes.length === trials && outcomes.every(o => o === 'passed') ? 'passed' : 'failed' };
});
await save();
console.log(`${report.passed ? 'PASS' : 'FAIL'}: ${report.summary.filter(s => s.status === 'passed').length}/${manifest.scenarios.length} required scenarios across ${trials} trials.`);
console.log(`Sanitized report: ${path.relative(root, path.join(output, 'regression.json'))}`);
process.exitCode = report.passed ? 0 : 1;
