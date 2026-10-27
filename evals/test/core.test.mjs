import test from 'node:test';
import assert from 'node:assert/strict';
import { assess, parseRecords, runProcess, validateManifest } from '../core.mjs';

const scenarios = [{ id: 'intake.text', engine: 'platform', category: 'intake', name: 'a real test' }];
const good = { name: 'a real test', status: 'passed', duration_ms: 12 };

test('all required scenarios must actually execute successfully', () => {
  assert.equal(assess(scenarios, [good], 0).passed, true);
  for (const [records, status] of [[[], 'missing'], [[{ ...good, status: 'skipped' }], 'skipped'],
    [[{ ...good, status: 'failed' }], 'failed'], [[good, good], 'duplicate']]) {
    const result = assess(scenarios, records, 0);
    assert.equal(result.passed, false);
    assert.equal(result.scenarios[0].status, status);
  }
});

test('a process failure or failing unmapped test blocks the whole gate', () => {
  assert.equal(assess(scenarios, [good], 1).passed, false);
  assert.equal(assess(scenarios, [good, { name: 'other', status: 'failed', duration_ms: 0 }], 0).passed, false);
  assert.equal(assess(scenarios, [good, { name: 'other', status: 'skipped', duration_ms: 0 }], 0).passed, false);
  assert.deepEqual(assess(scenarios,[good,{name:'other',status:'failed',duration_ms:0}],1).failed_tests,['other']);
});

test('malformed evidence cannot masquerade as a completed test', () => {
  assert.deepEqual(parseRecords('noise\nEVAL_RECORD ' + JSON.stringify(good) + '\n'), [good]);
  for (const line of ['EVAL_RECORD {', 'EVAL_RECORD null', 'EVAL_RECORD {"name":"x","status":"passed"}',
    'EVAL_RECORD {"name":"x","status":"passed","duration_ms":-1}']) {
    assert.throws(() => parseRecords(line));
  }
  assert.equal(assess(scenarios, [], 0).passed, false);
});

test('manifest rejects duplicate selectors and unknown engines instead of losing coverage', () => {
  assert.doesNotThrow(() => validateManifest({ version: 1, scenarios }));
  for (const data of [{ version: 1, scenarios: [] }, { version: 2, scenarios },
    { version: 1, scenarios: [scenarios[0], { ...scenarios[0], id: 'other.id' }] },
    { version: 1, scenarios: [{ ...scenarios[0], engine: 'live' }] }]) {
    assert.throws(() => validateManifest(data));
  }
});

test('runner bounds time and output, and reports missing executables safely', async () => {
  const ok = await runProcess(process.execPath, ['-e', 'console.log("ok")'], { timeoutMs: 1000 });
  assert.equal(ok.code, 0);
  assert.equal(ok.stdout.trim(), 'ok');
  const timed = await runProcess(process.execPath, ['-e', 'setInterval(()=>{},100)'], { timeoutMs: 100 });
  assert.equal(timed.reason, 'timeout');
  assert.notEqual(timed.code, 0);
  const large = await runProcess(process.execPath, ['-e', 'console.log("x".repeat(10000))'], { timeoutMs: 1000, maxOutputBytes: 100 });
  assert.equal(large.reason, 'output_limit');
  const absent = await runProcess('eval-does-not-exist-92731', [], { timeoutMs: 1000 });
  assert.equal(absent.reason, 'spawn_failed');
  assert.equal(absent.stdout, '');
});
