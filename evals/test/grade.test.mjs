import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { assessIntake, gradeDraft, validateCorpus } from '../grade.mjs';

const rubric = { id: 'literal', checks: [{ id: 'path', fields: ['scope'], pattern: 'docs/probe\\.txt' },
  { id: 'body', fields: ['acceptance_criteria'], pattern: 'probe-v2' }] };
const draft = { title: 'Create probe', context: 'Release check', objective: 'Create one file',
  scope: ['Create docs/probe.txt'], acceptance_criteria: ['Contains probe-v2'], constraints_or_open_questions: [] };

test('literal requirements must occur in their independently specified fields', () => {
  assert.equal(gradeDraft(rubric, draft).passed, true);
  const missing = { ...draft, scope: [], context: 'docs/probe.txt' };
  assert.equal(gradeDraft(rubric, missing).passed, false);
  assert.equal(gradeDraft(rubric, { ...draft, acceptance_criteria: ['Contains probe-v1'] }).passed, false);
});

test('malformed or fabricated output cannot pass on matching keywords', () => {
  for (const value of [null, {}, { ...draft, extra: 'injected' }, { ...draft, title: '' },
    { ...draft, scope: 'docs/probe.txt' }, { ...draft, acceptance_criteria: ['x'.repeat(1001)] }]) {
    assert.equal(gradeDraft(rubric, value).passed, false);
  }
});

test('forbidden actions and missing uncertainty fail distinct checks', () => {
  const scenario = { id: 'safety', checks: [
    { id: 'no_deploy', fields: ['scope'], pattern: '\\bdeploy to production\\b', absent: true },
    { id: 'uncertainty', fields: ['constraints_or_open_questions'], pattern: 'missing image' }
  ] };
  assert.equal(gradeDraft(scenario, { ...draft, scope: ['deploy to production'], constraints_or_open_questions: ['missing image'] }).passed, false);
  assert.equal(gradeDraft(scenario, draft).passed, false);
});

test('versioned corpus has independent positive and negative controls for every case', async () => {
  const corpus = JSON.parse(await readFile(new URL('../intake-cases.json', import.meta.url)));
  validateCorpus(corpus);
  assert.ok(corpus.cases.length >= 10);
  for (const scenario of corpus.cases) {
    assert.equal(gradeDraft(scenario, scenario.positive_control).passed, true, scenario.id);
    assert.equal(gradeDraft(scenario, scenario.negative_control).passed, false, scenario.id);
  }
  assert.throws(() => validateCorpus({ version: 1, cases: [] }));
  assert.throws(() => validateCorpus({ ...corpus, cases: [corpus.cases[0], corpus.cases[0]] }));
  const invalid = structuredClone(corpus);
  invalid.cases[0].checks[0].pattern = '[';
  assert.throws(() => validateCorpus(invalid));
});

test('live grading requires model provenance and exactly one completed output per case', () => {
  const output = 'EVAL_MODEL {"model":"configured-model"}\nEVAL_DRAFT ' + JSON.stringify({ id: 'literal', status: 'completed', draft }) + '\n';
  assert.equal(assessIntake([rubric], output, 0).passed, true);
  for (const value of [output.replace('EVAL_MODEL', 'OTHER'), output + output,
    output + 'EVAL_DRAFT {}\n', output + 'EVAL_DRAFT {\n', '']) {
    assert.equal(assessIntake([rubric], value, 0).passed, false);
  }
  assert.equal(assessIntake([rubric], output, 1).passed, false);
  const blocked = assessIntake([rubric], 'EVAL_BLOCKED missing_openai_configuration', 2);
  assert.equal(blocked.cases[0].status, 'blocked_configuration');
  assert.equal(blocked.passed, false);
});

test('corpus rejects negated facts, contradictory actions and wrong literal or numeric boundaries', async t => {
  const corpus = JSON.parse(await readFile(new URL('../intake-cases.json', import.meta.url)));
  const byId = id => corpus.cases.find(c => c.id === id);
  const correction = byId('correction.preserve_filename');
  await t.test('negated corrected content', () => assert.equal(gradeDraft(correction, { ...correction.positive_control,
    acceptance_criteria: ['Do not use probe-v2; the file must contain probe-v1.'] }).passed, false));
  const publication = byId('constraints.no_publication');
  await t.test('contradictory deployment', () => assert.equal(gradeDraft(publication, { ...publication.positive_control,
    scope: [...publication.positive_control.scope, 'Deploy the application'] }).passed, false));
  const exact = byId('text.exact_file');
  await t.test('wrong literal suffix', () => assert.equal(gradeDraft(exact, { ...exact.positive_control,
    acceptance_criteria: ['Contains exactly probe-v10 with no newline.'] }).passed, false));
  await t.test('missing newline', () => assert.equal(gradeDraft(exact, { ...exact.positive_control,
    acceptance_criteria: ['Contains exactly probe-v1 with no newline.'] }).passed, false));
  const numeric = byId('transcript.spanish_numeric');
  await t.test('wrong numeric prefix', () => assert.equal(gradeDraft(numeric, { ...numeric.positive_control,
    scope: ['Transición de 1500 milisegundos con prefers-reduced-motion'] }).passed, false));
});
