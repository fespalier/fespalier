import * as assert from 'node:assert/strict';
import { test } from 'node:test';

import { countBySeverity, groupByFile, parseFinding, parseFindings, toRange } from '../src/diagnostics';

// Real `fsp check --json` output (stdout).
const SAMPLE = [
  '{"file":"lib/app/bad--","line":null,"column":null,"severity":"warning","message":"folder has no page.dart and no routes below it; skipped"}',
  '{"file":"lib/app/products/$id/page.dart","line":1,"column":66,"severity":"error","message":"can\'t fill `nope`: it isn\'t a segment of this path ($id) or a query parameter (optional and nullable)"}',
  '',
].join('\n');

test('parses the JSON lines fsp prints', () => {
  const { findings, ignored } = parseFindings(SAMPLE);
  assert.deepEqual(ignored, []);
  assert.deepEqual(findings, [
    {
      file: 'lib/app/bad--',
      line: null,
      column: null,
      severity: 'warning',
      message: 'folder has no page.dart and no routes below it; skipped',
    },
    {
      file: 'lib/app/products/$id/page.dart',
      line: 1,
      column: 66,
      severity: 'error',
      message: "can't fill `nope`: it isn't a segment of this path ($id) or a query parameter (optional and nullable)",
    },
  ]);
});

test('lines that are not diagnostics are kept aside, not dropped silently', () => {
  const out = parseFindings('warming up\n{"file":"a.dart","severity":"error","message":"x"}\n{"other":1}\n[1]\n');
  assert.equal(out.findings.length, 1);
  assert.deepEqual(out.ignored, ['warming up', '{"other":1}', '[1]']);
});

test('windows line endings and blank lines are fine', () => {
  const line = '{"file":"a.dart","line":2,"column":3,"severity":"error","message":"m"}';
  assert.equal(parseFindings(`${line}\r\n\r\n${line}\r\n`).findings.length, 2);
});

test('an unknown severity or a missing field is not a diagnostic', () => {
  assert.equal(parseFinding('{"file":"a","severity":"info","message":"m"}'), undefined);
  assert.equal(parseFinding('{"file":"a","severity":"error"}'), undefined);
  assert.equal(parseFinding('{"severity":"error","message":"m"}'), undefined);
  assert.equal(parseFinding('null'), undefined);
});

test('a bad line or column becomes null instead of a wrong position', () => {
  const f = parseFinding('{"file":"a","line":0,"column":"3","severity":"error","message":"m"}');
  assert.equal(f?.line, null);
  assert.equal(f?.column, null);
});

test('positions become 0-based ranges; no position means the top of the file', () => {
  const at = (line: number | null, column: number | null) =>
    toRange({ file: 'f', line, column, severity: 'error', message: 'm' });
  assert.deepEqual(at(4, 7), { startLine: 3, startCharacter: 6, endLine: 3, endCharacter: 6 });
  assert.deepEqual(at(1, 1), { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 });
  assert.deepEqual(at(null, null), { startLine: 0, startCharacter: 0, endLine: 0, endCharacter: 0 });
  // A line without a column starts at the beginning of the line.
  assert.deepEqual(at(9, null), { startLine: 8, startCharacter: 0, endLine: 8, endCharacter: 0 });
});

test('groups by file and counts by severity', () => {
  const { findings } = parseFindings(SAMPLE + SAMPLE);
  const groups = groupByFile(findings);
  assert.deepEqual([...groups.keys()], ['lib/app/bad--', 'lib/app/products/$id/page.dart']);
  assert.equal(groups.get('lib/app/bad--')?.length, 2);
  assert.deepEqual(countBySeverity(findings), { errors: 2, warnings: 2 });
});
