import * as assert from 'node:assert/strict';
import { test } from 'node:test';

import { cmdLine, invocation, needsShell } from '../src/runner';

// The expected lines are what cross-spawn 7.0.6 writes for a `.bat` shim (escape.js: the command,
// then each argument with its metacharacters escaped twice), computed with it once.

test('only dart on Windows goes through a shell', () => {
  const dart = invocation('dart', 'fsp', true, 'check', 'C:\\app');
  assert.equal(needsShell(dart, 'win32'), true);
  assert.equal(needsShell(dart, 'linux'), false);
  assert.equal(needsShell(invocation('fsp', 'fsp', true, 'check', 'C:\\app'), 'win32'), false);
});

test('a project folder with a space stays one argument', () => {
  assert.equal(
    cmdLine(invocation('dart', 'fsp', false, 'check', 'C:\\Users\\First Last\\app')),
    'dart ^^^"run^^^" ^^^"fespalier^^^" ^^^"check^^^" ^^^"--json^^^" ^^^"--project^^^" ' +
      '^^^"C:\\Users\\First^^^ Last\\app^^^"',
  );
});

test('a folder name with an ampersand starts no command', () => {
  assert.equal(
    cmdLine(invocation('dart', 'fsp', false, 'gen', 'C:\\dev\\a&b')),
    'dart ^^^"run^^^" ^^^"fespalier^^^" ^^^"gen^^^" ^^^"--json^^^" ^^^"--project^^^" ^^^"C:\\dev\\a^^^&b^^^"',
  );
});

test('quotes, a trailing backslash, percent signs and parentheses', () => {
  assert.equal(
    cmdLine({ command: 'dart', args: ['run', '--json', '--project', 'C:\\x\\say "hi"\\'] }),
    'dart ^^^"run^^^" ^^^"--json^^^" ^^^"--project^^^" ^^^"C:\\x\\say^^^ \\^^^"hi\\^^^"\\\\^^^"',
  );
  assert.equal(
    cmdLine({ command: 'dart', args: ['run', 'fespalier', 'check', '--project', 'C:\\100%\\(x)'] }),
    'dart ^^^"run^^^" ^^^"fespalier^^^" ^^^"check^^^" ^^^"--project^^^" ^^^"C:\\100^^^%\\^^^(x^^^)^^^"',
  );
});
