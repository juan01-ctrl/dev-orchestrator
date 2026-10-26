const textFields = ['title', 'context', 'objective'];
const listFields = ['scope', 'acceptance_criteria', 'constraints_or_open_questions'];
const fields = [...textFields, ...listFields];
const byteLength = value => Buffer.byteLength(value, 'utf8');

function validDraft(draft) {
  if (!draft || Array.isArray(draft) || typeof draft !== 'object' || Object.keys(draft).sort().join(',') !== [...fields].sort().join(',')) return false;
  if (!textFields.every(f => typeof draft[f] === 'string' && draft[f].trim() && byteLength(draft[f]) <= (f === 'title' ? 160 : 2500))) return false;
  if (!listFields.every(f => Array.isArray(draft[f]) && draft[f].length <= 12 && draft[f].every(v => typeof v === 'string' && v.trim() && byteLength(v) <= 1000))) return false;
  return byteLength(fields.flatMap(f => draft[f]).join('')) <= 8000;
}

export function gradeDraft(scenario, draft) {
  const shape = validDraft(draft);
  const checks = [{ id: 'schema', passed: shape }];
  for (const rule of scenario.checks) {
    const text = shape ? rule.fields.flatMap(f => draft[f]).join('\n') : '';
    const matches = new RegExp(rule.pattern, 'iu').test(text);
    const contradicted = (rule.reject ?? []).some(pattern => new RegExp(pattern, 'iu').test(text));
    checks.push({ id: rule.id, passed: shape && !contradicted && (rule.absent === true ? !matches : matches) });
  }
  return { id: scenario.id, passed: checks.every(c => c.passed), checks };
}

export function validateCorpus(corpus) {
  if (corpus?.version !== 1 || !Array.isArray(corpus.cases) || !corpus.cases.length || corpus.cases.length > 20) throw new Error('Invalid corpus');
  const ids = new Set();
  for (const scenario of corpus.cases) {
    if (!/^[a-z][a-z0-9_.-]+$/.test(scenario.id ?? '') || ids.has(scenario.id) || !scenario.input || !Array.isArray(scenario.checks) || !scenario.checks.length) throw new Error('Invalid corpus scenario');
    ids.add(scenario.id);
    const checkIds = new Set();
    for (const rule of scenario.checks) {
      if (!rule.id || checkIds.has(rule.id) || !Array.isArray(rule.fields) || !rule.fields.length ||
        !rule.fields.every(f => fields.includes(f)) || typeof rule.pattern !== 'string' || !rule.pattern.length ||
        (rule.absent !== undefined && typeof rule.absent !== 'boolean')) throw new Error('Invalid grading rule');
      if (rule.reject !== undefined && (!Array.isArray(rule.reject) || !rule.reject.every(p => typeof p === 'string' && p.length))) throw new Error('Invalid contradiction rule');
      checkIds.add(rule.id); new RegExp(rule.pattern, 'iu');
      for (const pattern of rule.reject ?? []) new RegExp(pattern, 'iu');
    }
    if (!gradeDraft(scenario, scenario.positive_control).passed || gradeDraft(scenario, scenario.negative_control).passed) throw new Error('Invalid grader calibration');
  }
  return corpus;
}

export function assessIntake(cases, stdout, exitCode) {
  const rows = [], models = [];
  let invalid = false;
  try {
    for (const line of stdout.split('\n')) {
      if (line.startsWith('EVAL_MODEL ')) models.push(JSON.parse(line.slice(11)).model);
      if (line.startsWith('EVAL_DRAFT ')) rows.push(JSON.parse(line.slice(11)));
    }
  } catch { invalid = true; }
  const blocked = stdout.includes('EVAL_BLOCKED missing_openai_configuration');
  const outcomes = cases.map(scenario => {
    const found = rows.filter(r => r?.id === scenario.id);
    if (found.length !== 1 || found[0].status !== 'completed') return {
      id: scenario.id, passed: false, status: blocked ? 'blocked_configuration' : found.length > 1 ? 'duplicate_evidence' : 'provider_or_execution_failure'
    };
    const grade = gradeDraft(scenario, found[0].draft);
    return { ...grade, status: grade.passed ? 'passed' : 'failed' };
  });
  const validModel = models.length === 1 && typeof models[0] === 'string' && models[0].length > 0 && models[0].length <= 100 && /^[a-zA-Z0-9._:/-]+$/.test(models[0]);
  const validRows = rows.length === cases.length && rows.every(r => cases.some(c => c.id === r?.id));
  return {
    passed: exitCode === 0 && !invalid && validModel && validRows && outcomes.every(o => o.passed),
    model: validModel ? models[0] : null, blocked, cases: outcomes
  };
}
