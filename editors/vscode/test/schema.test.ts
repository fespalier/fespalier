import * as assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';

// The tests run from out/test/; the extension's own files are two folders up.
const root = path.join(__dirname, '..', '..');

interface YamlValidation {
  fileMatch: string | string[];
  url: string;
}

function contributions(): YamlValidation[] {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  return pkg.contributes.yamlValidation as YamlValidation[];
}

test('the YAML extension gets one schema for pubspec.yaml, shipped in the package', () => {
  const entries = contributions();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].fileMatch, 'pubspec.yaml');
  // A path relative to the extension: the YAML extension resolves `./` against it.
  assert.ok(entries[0].url.startsWith('./schemas/'), entries[0].url);
  const file = path.join(root, entries[0].url);
  assert.ok(fs.existsSync(file), file);
  // .vscodeignore leaves out everything it does not name: the schema has to be named.
  const ignore = fs.readFileSync(path.join(root, '.vscodeignore'), 'utf8').split(/\r?\n/);
  assert.ok(ignore.includes('!schemas/**'), '.vscodeignore must keep schemas/');
});

test('the schema keeps the pubspec schema and adds the fespalier: section', () => {
  const file = path.join(root, contributions()[0].url);
  const schema = JSON.parse(fs.readFileSync(file, 'utf8'));
  // The YAML extension applies only its highest-priority schemas to a file, and an extension's
  // outranks the JSON Schema Store's: this one must bring the store's pubspec schema with it.
  assert.deepEqual(schema.allOf, [{ $ref: 'https://www.schemastore.org/pubspec.json' }]);
  assert.deepEqual(schema.properties.fespalier.anyOf, [{ $ref: '#/definitions/fespalier' }, { type: 'null' }]);
  const section = schema.definitions.fespalier;
  assert.equal(section.additionalProperties, false);
  for (const key of ['app_dir', 'output', 'main', 'tasks', 'adapters']) {
    assert.ok(key in section.properties, key);
  }
  // Every reference resolves inside the file, but the store's.
  const refs = JSON.stringify(schema).match(/"\$ref":"[^"]*"/g) ?? [];
  for (const ref of refs) {
    const target = JSON.parse(`{${ref}}`).$ref as string;
    if (target.startsWith('https://')) {
      continue;
    }
    assert.ok(target.startsWith('#/definitions/'), target);
    assert.ok(target.slice('#/definitions/'.length) in schema.definitions, target);
  }
});
