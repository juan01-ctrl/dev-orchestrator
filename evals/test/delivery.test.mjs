import test from 'node:test';
import assert from 'node:assert/strict';
import { gradeDelivery } from '../delivery.mjs';

const expected = { repository: 'example/test', number: 17, branch: 'task-attempts/run/attempt-1', base: 'main',
  file: 'docs/probe.txt', content: 'probe-v3\n', previous_head: 'a'.repeat(40) };
const evidence = { repository: 'example/test', number: 17, branch: 'task-attempts/run/attempt-1', base: 'main',
  head: 'b'.repeat(40), state: 'open', merged: false, changed_files: ['docs/probe.txt'],
  file_ref: 'b'.repeat(40), file_content_base64: 'cHJvYmUtdjMK' };

test('grade the actual PR identity, exact bytes and sole changed file, not agent claims', () => {
  assert.equal(gradeDelivery(expected, evidence).passed, true);
  for (const patch of [{ number: 18 }, { repository: 'other/repo' }, { branch: 'another-branch' },
    { base: 'develop' }, { state: 'closed' }, { merged: true }, { changed_files: ['docs/probe.txt', 'src/app.ts'] },
    { file_ref: 'a'.repeat(40) }, { head: 'a'.repeat(40), file_ref: 'a'.repeat(40) },
    { file_content_base64: 'cHJvYmUtdjM=' }, { file_content_base64: 'not base64!' }]) {
    assert.equal(gradeDelivery(expected, { ...evidence, ...patch }).passed, false, JSON.stringify(patch));
  }
});

test('missing provider evidence cannot pass a delivery eval', () => {
  assert.equal(gradeDelivery(expected, {}).passed, false);
  assert.equal(gradeDelivery(expected, null).passed, false);
  assert.throws(() => gradeDelivery({}, evidence));
});
