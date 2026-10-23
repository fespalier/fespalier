import * as assert from 'node:assert/strict';
import { test } from 'node:test';

import { fspCommand, needsShell } from '../src/runner';
import { parseTaskList, readDefinition, taskArgs, taskLabel, taskListFailure } from '../src/tasks';

// Real `fsp run --json` output (stdout), fsp 0.22.0.
const SAMPLE = [
  '{"name":"dev","args":["dev"],"needs_target":false,"run":"flutter run","declared":true}',
  '{"name":"build","args":["build"],"needs_target":true,"run":"flutter build","declared":false}',
  '{"name":"codegen","args":["run","codegen"],"needs_target":false,"run":"dart run build_runner build","declared":true}',
  '',
].join('\n');

test('parses the JSON lines fsp run --json prints', () => {
  const { tasks, ignored } = parseTaskList(SAMPLE);
  assert.deepEqual(ignored, []);
  assert.deepEqual(tasks.map((t) => [t.name, t.args, t.needsTarget, t.declared]), [
    ['dev', ['dev'], false, true],
    ['build', ['build'], true, false],
    ['codegen', ['run', 'codegen'], false, true],
  ]);
  assert.equal(tasks[2].run, 'dart run build_runner build');
});

test('a line that is not a task is set aside', () => {
  const out = parseTaskList('hi\n{"name":"x","args":[],"run":"y"}\n{"name":"x","args":["run",1],"run":"y"}\n[1]\n{"name":"ok","args":["run","ok"],"run":"r"}\r\n');
  assert.equal(out.tasks.length, 1);
  assert.equal(out.ignored.length, 4);
});

test('task definitions become fsp arguments', () => {
  assert.deepEqual(taskArgs({ task: 'dev' }), ['dev']);
  assert.deepEqual(taskArgs({ task: 'dev', args: ['-d', 'chrome'] }), ['dev', '--', '-d', 'chrome']);
  assert.deepEqual(taskArgs({ task: 'build', target: 'web' }), ['build', 'web']);
  assert.deepEqual(taskArgs({ task: 'build' }), { error: 'the build task needs a "target": what flutter build builds (apk, web, ios, ...)' });
  assert.deepEqual(taskArgs({ task: 'codegen', args: ['--x'] }), ['run', 'codegen', '--', '--x']);
});

test('labels name the project only when a folder has several', () => {
  assert.equal(taskLabel('codegen', '', false), 'codegen');
  assert.equal(taskLabel('codegen', 'examples/shop', true), 'codegen - examples/shop');
  assert.equal(taskLabel('codegen', '', true), 'codegen - .');
});

test('why the list failed', () => {
  const old = 'this fsp cannot list tasks: `fsp run --json` needs fespalier 0.22.0 or later';
  assert.equal(taskListFailure(2, "error: unexpected argument '--json' found\n\nUsage: fsp run [OPTIONS] [TASK] [-- <ARGS>...]\n"), old);
  assert.equal(taskListFailure(1, '`fespalier.tasks.codegen` must be ...\n'), '`fespalier.tasks.codegen` must be ...');
  assert.equal(taskListFailure(3, ''), 'exited with code 3');
  assert.equal(taskListFailure(null, '', 'spawn fsp ENOENT'), 'spawn fsp ENOENT');
});

test('a clap error is told by its error: line, not by the line that ends it', () => {
  const help = "\nFor more information, try '--help'.\n";
  // fsp before 0.9.0 has no `run` at all: the old-fsp sentence, as for an fsp that has no --json.
  const noRun = `error: unrecognized subcommand 'run'\n\n  tip: a similar subcommand exists: 'gen'\n\nUsage: fsp [OPTIONS] <COMMAND>\n${help}`;
  assert.equal(taskListFailure(2, noRun), 'this fsp cannot list tasks: `fsp run --json` needs fespalier 0.22.0 or later');
  const other = `error: unexpected argument '--project' found\n\nUsage: fsp run [OPTIONS] [TASK] [-- <ARGS>...]\n${help}`;
  assert.equal(taskListFailure(2, other), "error: unexpected argument '--project' found");
  // fsp's own errors have no prefix and are one line; a warning above them does not hide them.
  assert.equal(taskListFailure(1, 'warning: x\n`fespalier.tasks.codegen` must be ...\n'), '`fespalier.tasks.codegen` must be ...');
  assert.equal(taskListFailure(1, 'warning: x\nerror: y\nmore\n'), 'error: y');
});

test('tasks.json types are checked before they are used', () => {
  assert.deepEqual(readDefinition({ type: 'fespalier', task: 'codegen', path: 'apps/shop', target: 'web', args: ['--x'] }), {
    task: 'codegen',
    path: 'apps/shop',
    target: 'web',
    args: ['--x'],
  });
  assert.deepEqual(readDefinition({ task: 'dev' }), { task: 'dev' });
  assert.deepEqual(readDefinition({ task: 'x', args: [] }), { task: 'x', args: [] });
  assert.deepEqual(readDefinition({ task: 'x', args: '--release' }), { error: '"args" must be a list of strings, got "--release"' });
  assert.deepEqual(readDefinition({ task: 'x', args: ['a', null] }), { error: '"args" must be a list of strings, got ["a",null]' });
  assert.deepEqual(readDefinition({ task: 'x', target: 1 }), { error: '"target" must be a string, got 1' });
  assert.deepEqual(readDefinition({ task: 'x', path: {} }), { error: '"path" must be a string, got {}' });
  assert.deepEqual(readDefinition({ task: '  ' }), { error: 'the "task" must be a name from `fespalier: tasks:`, or dev or build' });
  assert.deepEqual(readDefinition({}), { error: 'the "task" must be a name from `fespalier: tasks:`, or dev or build' });
  assert.deepEqual(readDefinition(undefined), { error: 'the task has no definition' });
  assert.deepEqual(readDefinition(null), { error: 'the task has no definition' });
});

test('fsp or dart run fespalier, and when a shell is needed', () => {
  assert.deepEqual(fspCommand('auto', 'fsp', true, ['run', '--json']), { command: 'fsp', args: ['run', '--json'] });
  assert.deepEqual(fspCommand('auto', 'fsp', false, ['dev']), { command: 'dart', args: ['run', 'fespalier', 'dev'] });
  assert.equal(needsShell({ command: 'dart', args: [] }, 'win32'), true);
  assert.equal(needsShell({ command: 'dart', args: [] }, 'linux'), false);
  assert.equal(needsShell({ command: 'fsp', args: [] }, 'win32'), false);
});
