// Evidence must come from authenticated provider reads at the exact PR head.
// This checks supplied snapshots; it does not authenticate their provenance.
export function gradeDelivery(expected, evidence) {
  if (!expected || !['repository', 'branch', 'base', 'file', 'content'].every(k => typeof expected[k] === 'string' && expected[k].length) ||
    !Number.isSafeInteger(expected.number) || expected.number < 1) throw new Error('Invalid delivery expectation');
  const actual = evidence ?? {};
  let contentMatches = false;
  if (typeof actual.file_content_base64 === 'string' && actual.file_content_base64.length <= 1_000_000) {
    const encoded = actual.file_content_base64.replace(/\s/g, '');
    const decoded = Buffer.from(encoded, 'base64');
    contentMatches = decoded.toString('base64') === encoded && decoded.equals(Buffer.from(expected.content, 'utf8'));
  }
  const checks = [
    { id: 'repository', passed: actual.repository === expected.repository },
    { id: 'same_pr', passed: actual.number === expected.number },
    { id: 'same_branch', passed: actual.branch === expected.branch },
    { id: 'base', passed: actual.base === expected.base },
    { id: 'open_unmerged', passed: actual.state === 'open' && actual.merged === false },
    { id: 'head_integrity', passed: typeof actual.head === 'string' && /^[a-f0-9]{40,64}$/.test(actual.head) && actual.file_ref === actual.head },
    { id: 'sole_changed_file', passed: Array.isArray(actual.changed_files) && actual.changed_files.length === 1 && actual.changed_files[0] === expected.file },
    { id: 'exact_file_bytes', passed: contentMatches },
    { id: 'new_commit', passed: !expected.previous_head || (typeof actual.head === 'string' && actual.head !== expected.previous_head) }
  ];
  return { passed: checks.every(c => c.passed), checks };
}
