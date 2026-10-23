import * as assert from 'node:assert/strict';
import { test } from 'node:test';
import type { Task } from 'vscode';

import type { Invocation, RunResult } from '../src/runner';
import { folder, installFakeVscode } from './fakeVscode';

// The provider imports `vscode`: stand in for it before it is loaded.
const vs = installFakeVscode([folder('/ws')]);
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { FespalierTaskProvider } = require('../src/taskProvider') as typeof import('../src/taskProvider');

const DEV = '{"name":"dev","args":["dev"],"needs_target":false,"run":"flutter run","declared":false}';
const BUILD = '{"name":"build","args":["build"],"needs_target":true,"run":"flutter build","declared":false}';
const CODEGEN =
  '{"name":"codegen","args":["run","codegen"],"needs_target":false,"run":"dart run build_runner build","declared":true}';
const OK: RunResult = { code: 0, stdout: `${DEV}\n${BUILD}\n${CODEGEN}\n`, stderr: '' };
const OLD_FSP: RunResult = {
  code: 2,
  stdout: '',
  stderr:
    "error: unexpected argument '--json' found\n\nUsage: fsp run [OPTIONS] [TASK] [-- <ARGS>...]\n\nFor more information, try '--help'.\n",
};
const OLD_FSP_TEXT = 'this fsp cannot list tasks: `fsp run --json` needs fespalier 0.22.0 or later';
const MISTAKE: RunResult = { code: 1, stdout: '', stderr: '`fespalier.tasks.codegen` must be a command\n' };

interface World {
  projects: string[];
  /** What `fsp run --json` answers in each project. */
  answers: Map<string, RunResult>;
  /** The projects `fsp run --json` ran in, in order. */
  runs: string[];
  logs: string[];
  pubspecs: Set<string>;
  provider: InstanceType<typeof FespalierTaskProvider>;
}

function world(projects: string[], answer: RunResult = OK, folders = [folder('/ws')]): World {
  vs.folders = folders;
  vs.warnings.length = 0;
  vs.errors.length = 0;
  const w: World = {
    projects,
    answers: new Map(projects.map((p) => [p, answer])),
    runs: [],
    logs: [],
    pubspecs: new Set(['/ws']),
    provider: undefined as unknown as World['provider'],
  };
  w.provider = new FespalierTaskProvider({
    findProjects: async () => w.projects.map((root) => ({ root })),
    command: async (args: string[]): Promise<Invocation> => ({ command: 'fsp', args }),
    run: async (_inv: Invocation, cwd: string) => {
      w.runs.push(cwd);
      return w.answers.get(cwd) ?? OK;
    },
    hasPubspec: (root: string) => w.pubspecs.has(root),
    log: (line: string) => w.logs.push(line),
  });
  return w;
}

interface Exec {
  process: string;
  args: string[];
  options: { cwd: string };
}
const exec = (t: Task) => t.execution as unknown as Exec;
const names = (tasks: Task[]) => tasks.map((t) => t.name);

test('a list that worked is kept for each project until invalidate', async () => {
  const w = world(['/ws/a', '/ws/b']);
  await w.provider.provideTasks();
  await w.provider.provideTasks();
  assert.deepEqual(w.runs, ['/ws/a', '/ws/b']);
  w.provider.invalidate();
  await w.provider.provideTasks();
  assert.deepEqual(w.runs, ['/ws/a', '/ws/b', '/ws/a', '/ws/b']);
});

test('a failed list is asked for again, the others are not', async () => {
  const w = world(['/ws/a', '/ws/b']);
  w.answers.set('/ws/a', OLD_FSP);
  const first = await w.provider.provideTasks();
  assert.deepEqual(names(first), ['dev - b', 'codegen - b']);
  w.answers.set('/ws/a', OK); // the user ran `fsp upgrade`
  const second = await w.provider.provideTasks();
  assert.deepEqual(w.runs, ['/ws/a', '/ws/b', '/ws/a']);
  assert.deepEqual(names(second), ['dev - a', 'codegen - a', 'dev - b', 'codegen - b']);
});

test('an fsp that cannot list is told once, not once for each project', async () => {
  const w = world(['/ws/a', '/ws/b', '/ws/c'], OLD_FSP);
  assert.deepEqual(await w.provider.provideTasks(), []);
  assert.deepEqual(vs.warnings, [`fespalier: could not list the tasks: ${OLD_FSP_TEXT}`]);
  await w.provider.provideTasks();
  assert.equal(vs.warnings.length, 1);
  assert.equal(w.logs.length, 6); // the output channel has every failure
  assert.match(w.logs[0], /^\$ fsp run --json\n/);
  // It works once, then is old again (a different fsp on PATH): told again.
  for (const p of w.projects) {
    w.answers.set(p, OK);
  }
  await w.provider.provideTasks();
  for (const p of w.projects) {
    w.answers.set(p, OLD_FSP);
  }
  w.provider.invalidate();
  await w.provider.provideTasks();
  assert.equal(vs.warnings.length, 2);
});

test('no fsp at all is told once as well', async () => {
  const w = world(['/ws/a', '/ws/b'], { code: null, stdout: '', stderr: '', spawnError: 'spawn fsp ENOENT' });
  await w.provider.provideTasks();
  assert.deepEqual(vs.warnings, ['fespalier: could not list the tasks: spawn fsp ENOENT']);
});

test("a project's own mistake is told once for the project and the reason", async () => {
  const w = world(['/ws/a', '/ws/b'], MISTAKE);
  await w.provider.provideTasks();
  assert.deepEqual(vs.warnings, [
    'fespalier: could not list the tasks of a: `fespalier.tasks.codegen` must be a command',
    'fespalier: could not list the tasks of b: `fespalier.tasks.codegen` must be a command',
  ]);
  await w.provider.provideTasks();
  assert.equal(vs.warnings.length, 2);
  w.answers.set('/ws/a', { code: 1, stdout: '', stderr: 'no pubspec.yaml found\n' });
  await w.provider.provideTasks();
  assert.equal(vs.warnings.length, 3);
  assert.match(vs.warnings[2], /of a: no pubspec\.yaml found$/);
});

test('a task is named after its project only when a folder has several', async () => {
  const one = world(['/ws']);
  const tasks = await one.provider.provideTasks();
  assert.deepEqual(names(tasks), ['dev', 'codegen']); // build needs a target: a tasks.json entry
  const [dev, codegen] = tasks;
  assert.deepEqual(codegen.definition, { type: 'fespalier', task: 'codegen' });
  assert.equal(codegen.detail, 'dart run build_runner build');
  assert.equal(dev.detail, 'flutter run');
  assert.deepEqual([exec(codegen).process, exec(codegen).args, exec(codegen).options], [
    'fsp',
    ['run', 'codegen'],
    { cwd: '/ws' },
  ]);
  assert.deepEqual(exec(dev).args, ['dev']);
  assert.equal((dev.presentationOptions as { focus: boolean }).focus, true);
  assert.equal((codegen.presentationOptions as { focus: boolean }).focus, false);

  const several = world(['/ws/apps/shop', '/ws/examples/shop']);
  const both = await several.provider.provideTasks();
  assert.deepEqual(names(both), [
    'dev - apps/shop',
    'codegen - apps/shop',
    'dev - examples/shop',
    'codegen - examples/shop',
  ]);
  assert.deepEqual(both[1].definition, { type: 'fespalier', task: 'codegen', path: 'apps/shop' });
  assert.equal(exec(both[3]).options.cwd, '/ws/examples/shop');

  // Two workspace folders with one project each: no suffix, but the path is still there.
  const folders = world(['/w1', '/w2/app'], OK, [folder('/w1'), folder('/w2')]);
  const separate = await folders.provider.provideTasks();
  assert.deepEqual(names(separate), ['dev', 'codegen', 'dev', 'codegen']);
  assert.equal((separate[0].definition as { path?: string }).path, undefined);
  assert.equal((separate[2].definition as { path?: string }).path, 'app');
});

function entry(definition: Record<string, unknown>): Task {
  return { definition: { type: 'fespalier', ...definition }, scope: folder('/ws'), name: 'x' } as unknown as Task;
}

test('a tasks.json entry becomes a task running in its project', async () => {
  const w = world(['/ws']);
  w.pubspecs.add('/ws/apps/shop');
  const plain = entry({ task: 'codegen', args: ['--x'] });
  const a = (await w.provider.resolveTask(plain)) as Task;
  assert.equal(a.definition, plain.definition); // the very object, as the API requires
  assert.deepEqual([exec(a).args, exec(a).options.cwd], [['run', 'codegen', '--', '--x'], '/ws']);
  const b = (await w.provider.resolveTask(entry({ task: 'build', target: 'web', args: ['--release'], path: 'apps/shop' }))) as Task;
  assert.deepEqual([exec(b).args, exec(b).options.cwd], [['build', 'web', '--', '--release'], '/ws/apps/shop']);
  assert.deepEqual(vs.errors, []);
  assert.deepEqual(w.runs, []);
});

test('a tasks.json entry of the wrong types is refused, not run', async () => {
  const w = world(['/ws']);
  const bad: [Record<string, unknown>, RegExp][] = [
    [{ task: 'codegen', args: '--release' }, /"args" must be a list of strings, got "--release"/],
    [{ task: 'codegen', args: ['ok', 3] }, /"args" must be a list of strings/],
    [{ task: 'codegen', target: 7 }, /"target" must be a string, got 7/],
    [{ task: 'codegen', path: ['apps'] }, /"path" must be a string/],
    [{ task: 5 }, /"task" must be a name/],
    [{ task: 'build' }, /the build task needs a "target"/],
  ];
  for (const [definition, message] of bad) {
    assert.equal(await w.provider.resolveTask(entry(definition)), undefined);
    assert.match(vs.errors[vs.errors.length - 1], message);
  }
  assert.equal(vs.errors.length, bad.length);
  assert.ok(vs.errors.every((e) => e.startsWith('fespalier: ')));
});

test('a folder with no pubspec.yaml is refused, not run where fsp would walk up', async () => {
  const w = world(['/ws']);
  assert.equal(await w.provider.resolveTask(entry({ task: 'codegen', path: 'apps/nope' })), undefined);
  assert.equal(
    vs.errors[0],
    'fespalier: there is no pubspec.yaml in /ws/apps/nope: set "path" to the project\'s folder, relative to the workspace folder',
  );
  // Asked again (VS Code resolves tasks.json often): logged each time, shown once.
  assert.equal(await w.provider.resolveTask(entry({ task: 'codegen', path: 'apps/nope' })), undefined);
  assert.equal(vs.errors.length, 1);
  assert.equal(w.logs.length, 2);
  w.pubspecs.delete('/ws');
  assert.equal(await w.provider.resolveTask(entry({ task: 'codegen' })), undefined);
  assert.match(vs.errors[1], /no pubspec\.yaml in \/ws:/);
});
