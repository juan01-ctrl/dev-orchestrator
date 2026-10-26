import { spawn } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const statuses = new Set(['passed', 'failed', 'skipped']);

export function validateManifest(manifest) {
  if (manifest?.version !== 1 || !Array.isArray(manifest.scenarios) || !manifest.scenarios.length) {
    throw new Error('Invalid or empty eval manifest');
  }
  const ids = new Set(), selectors = new Set();
  for (const item of manifest.scenarios) {
    if (!/^[a-z][a-z0-9_.-]{1,100}$/.test(item.id ?? '') || !['platform', 'connector'].includes(item.engine) ||
      typeof item.category !== 'string' || !item.category || typeof item.name !== 'string' || !item.name ||
      ids.has(item.id) || selectors.has(`${item.engine}:${item.name}`)) throw new Error('Invalid or duplicate eval scenario');
    ids.add(item.id); selectors.add(`${item.engine}:${item.name}`);
  }
  return manifest;
}

export function parseRecords(stdout) {
  return stdout.split('\n').filter(line => line.startsWith('EVAL_RECORD ')).map(line => {
    const item = JSON.parse(line.slice(12));
    if (!item || typeof item.name !== 'string' || !item.name.length || item.name.length > 1000 ||
      !statuses.has(item.status) || !Number.isFinite(item.duration_ms) || item.duration_ms < 0) {
      throw new Error('Malformed eval evidence');
    }
    return { name: item.name, status: item.status, duration_ms: item.duration_ms };
  });
}

export function assess(scenarios, records, exitCode) {
  const cases = scenarios.map(item => {
    const found = records.filter(record => record.name === item.name);
    const status = found.length === 0 ? 'missing' : found.length > 1 ? 'duplicate' : found[0].status;
    return { id: item.id, category: item.category, status, duration_ms: found.reduce((n, r) => n + r.duration_ms, 0) };
  });
  return {
    passed: exitCode === 0 && records.length > 0 && records.every(r => r.status === 'passed') && cases.every(c => c.status === 'passed'),
    tests_executed: records.length,
    tests_failed: records.filter(r => r.status === 'failed').length,
    tests_skipped: records.filter(r => r.status === 'skipped').length,
    scenarios: cases
  };
}

// Children are eval-only processes. Never target the customer's running executor.
export function runProcess(command, args, { cwd, env = {}, timeoutMs = 180_000, maxOutputBytes = 8 * 1024 * 1024 } = {}) {
  return new Promise(resolve => {
    const started = performance.now();
    let stdout = '', bytes = 0, reason = null, settled = false;
    const child = spawn(command, args, { cwd, env: { ...process.env, ...env }, detached: process.platform !== 'win32', stdio: ['ignore', 'pipe', 'pipe'] });
    const stop = why => {
      reason ??= why;
      try { if (process.platform !== 'win32') process.kill(-child.pid, 'SIGKILL'); else child.kill('SIGKILL'); } catch { /* already exited */ }
    };
    const timer = setTimeout(() => stop('timeout'), timeoutMs);
    const finish = code => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      resolve({ code: reason ? 1 : (code ?? 1), reason, stdout, duration_ms: Math.round(performance.now() - started) });
    };
    const consume = (chunk, capture) => {
      bytes += chunk.length;
      if (bytes > maxOutputBytes) { stop('output_limit'); return; }
      if (capture) stdout += chunk.toString('utf8');
    };
    child.stdout.on('data', chunk => consume(chunk, true));
    child.stderr.on('data', chunk => consume(chunk, false));
    child.on('error', () => { reason = 'spawn_failed'; finish(127); });
    child.on('close', finish);
  });
}
