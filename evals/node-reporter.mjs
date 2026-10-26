// Strip diagnostics, command output, errors and other potentially private data.
export default async function* report(source) {
  for await (const event of source) {
    if (!['test:pass', 'test:fail'].includes(event.type) || event.data.details?.type === 'suite') continue;
    const { name, skip, todo, details } = event.data;
    yield 'EVAL_RECORD ' + JSON.stringify({
      name, status: skip || todo ? 'skipped' : event.type === 'test:pass' ? 'passed' : 'failed',
      duration_ms: details?.duration_ms ?? 0
    }) + '\n';
  }
}
