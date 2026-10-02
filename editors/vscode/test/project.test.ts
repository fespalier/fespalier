import * as assert from 'node:assert/strict';
import { test } from 'node:test';

import { affectsCheck, appDirFromPubspec, isUnderAppDir, normalizeDir } from '../src/project';
import { invocation } from '../src/runner';

test('app_dir defaults to lib/app', () => {
  assert.equal(appDirFromPubspec('name: demo\n'), 'lib/app');
  assert.equal(appDirFromPubspec('name: demo\nfespalier:\n  output: lib/x.g.dart\n'), 'lib/app');
});

test('reads app_dir from the fespalier section', () => {
  const yaml = ['name: demo', 'fespalier:', '  # where the routes are', '  app_dir: lib/screens/  # trailing', '  format: true', ''].join('\n');
  assert.equal(appDirFromPubspec(yaml), 'lib/screens');
  assert.equal(appDirFromPubspec('fespalier:\n  app_dir: "./lib/routes"\n'), 'lib/routes');
  assert.equal(appDirFromPubspec("fespalier:\r\n  app_dir: 'lib\\pages'\r\n"), 'lib/pages');
});

test('an app_dir under another key is not the fespalier one', () => {
  assert.equal(appDirFromPubspec('other:\n  app_dir: lib/no\nfespalier:\n  format: true\nlater:\n  app_dir: lib/no\n'), 'lib/app');
});

test('saved files: inside the app folder or not', () => {
  assert.equal(isUnderAppDir('lib/app/products/$id/page.dart', 'lib/app'), true);
  assert.equal(isUnderAppDir('lib/app', 'lib/app'), true);
  assert.equal(isUnderAppDir('lib/app.g.dart', 'lib/app'), false);
  assert.equal(isUnderAppDir('lib/application/page.dart', 'lib/app'), false);
  assert.equal(isUnderAppDir('lib/main.dart', 'lib/app'), false);
  assert.equal(isUnderAppDir('lib\\app\\page.dart', './lib/app/'), true);
});

test('saved files that can change what fsp check finds', () => {
  // The route tree, and pubspec.yaml (it can move the app folder).
  assert.equal(affectsCheck('pubspec.yaml', 'lib/app'), true);
  assert.equal(affectsCheck('lib/app/products/$id/page.dart', 'lib/app'), true);
  assert.equal(affectsCheck('lib/app/_widgets/card.dart', 'lib/app'), true);
  // A Dart file anywhere under lib/ can hold a string path (since 0.7.0).
  assert.equal(affectsCheck('lib/screens/home.dart', 'lib/app'), true);
  assert.equal(affectsCheck('lib/main.dart', 'lib/app'), true);
  assert.equal(affectsCheck('lib\\screens\\home.dart', 'lib/app'), true);
  assert.equal(affectsCheck('lib/application/page.dart', 'lib/app'), true);
  // Not what fsp generates, not code, and not under lib/.
  assert.equal(affectsCheck('lib/app.g.dart', 'lib/app'), false);
  assert.equal(affectsCheck('lib/screens/x.g.dart', 'lib/app'), false);
  assert.equal(affectsCheck('lib/assets/logo.png', 'lib/app'), false);
  assert.equal(affectsCheck('test/app_test.dart', 'lib/app'), false);
  assert.equal(affectsCheck('README.md', 'lib/app'), false);
  assert.equal(affectsCheck('example/lib/main.dart', 'lib/app'), false);
});

test('normalizeDir', () => {
  assert.equal(normalizeDir(' ./lib//app/ '), 'lib//app');
  assert.equal(normalizeDir('lib\\app\\'), 'lib/app');
});

test('the runner: fsp when available, dart run fespalier otherwise', () => {
  const tail = ['check', '--json', '--project', '/p'];
  assert.deepEqual(invocation('auto', 'fsp', true, 'check', '/p'), { command: 'fsp', args: tail });
  assert.deepEqual(invocation('auto', 'fsp', false, 'check', '/p'), {
    command: 'dart',
    args: ['run', 'fespalier', ...tail],
  });
  assert.equal(invocation('dart', 'fsp', true, 'gen', '/p').command, 'dart');
  assert.deepEqual(invocation('fsp', '/opt/fsp', false, 'gen', '/p'), {
    command: '/opt/fsp',
    args: ['gen', '--json', '--project', '/p'],
  });
});
