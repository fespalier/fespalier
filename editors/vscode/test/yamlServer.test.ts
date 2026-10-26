import * as assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';

import { TextDocument } from 'vscode-languageserver-textdocument';
import { getLanguageService, LanguageService, SchemaPriority } from 'yaml-language-server';

// The engine of the YAML extension (redhat.vscode-yaml), as its client sets it up for a
// pubspec.yaml: the JSON Schema Store's pubspec schema at the store's priority, and the schema this
// extension contributes (`contributes.yamlValidation`) at the priority of an extension's. The
// server applies the schemas of the highest priority only, so the contributed one must carry the
// store's checks itself. No network: the store's schema is a stand-in from test/fixtures.

const root = path.join(__dirname, '..', '..');
const STORE = 'https://www.schemastore.org/pubspec.json';
const ours = path.join(root, 'schemas', 'pubspec.schema.json');
const oursUri = pathToFileURL(ours).toString();

function service(withOurs: boolean, storeUp = true): LanguageService {
  const ls = getLanguageService({
    schemaRequestService: async (uri: string) => {
      if (uri === STORE && storeUp) {
        return fs.readFileSync(path.join(root, 'test', 'fixtures', 'store-pubspec.json'), 'utf8');
      }
      if (uri === oursUri) {
        return fs.readFileSync(ours, 'utf8');
      }
      // The server also looks for a remote schema beside the local one that names it.
      throw new Error(`not available: ${uri}`);
    },
    workspaceContext: { resolveRelativePath: (rel: string, res: string) => new URL(rel, res).toString() },
  });
  const schemas = [{ uri: STORE, fileMatch: ['pubspec.yaml'], priority: SchemaPriority.SchemaStore }];
  if (withOurs) {
    schemas.push({ uri: oursUri, fileMatch: ['/pubspec.yaml'], priority: SchemaPriority.SchemaAssociation });
  }
  ls.configure({ validate: true, completion: true, hover: true, schemas });
  return ls;
}

let n = 0;
function doc(lines: string[]): TextDocument {
  // A new URI each time: the server caches a parsed document by URI and version.
  n += 1;
  return TextDocument.create(`file:///app${n}/pubspec.yaml`, 'yaml', 1, lines.join('\n'));
}

const PUBSPEC = [
  'name: shop',
  'environment:',
  '  sdk: 3',
  'fespalier:',
  '  app_dirr: lib/app',
  '  remount: sometimes',
  '  adapters: auto',
  '  tasks:',
  '    dev:',
  '      hot_reload: maybe',
  '',
];

async function problems(ls: LanguageService, d: TextDocument): Promise<string[]> {
  return (await ls.doValidation(d, false)).map((p) => `${p.range.start.line + 1}: ${p.message}`).sort();
}

test("the store's schema alone knows nothing of fespalier:", async () => {
  assert.deepEqual(await problems(service(false), doc(PUBSPEC)), ['3: Incorrect type. Expected "string".']);
});

test("with the extension's schema, the store's checks stay and the section is checked", async () => {
  assert.deepEqual(await problems(service(true), doc(PUBSPEC)), [
    '10: Incorrect type. Expected "boolean".',
    '3: Incorrect type. Expected "string".',
    '5: Property app_dirr is not allowed.',
    '6: Value is not accepted. Valid values: "never", "on_segments", "on_location".',
  ]);
  assert.deepEqual(await problems(service(true), doc(['name: shop', 'fespalier:', ''])), []);
});

test('keys complete at the top and in the section, and a key has its description', async () => {
  const ls = service(true);
  const top = await ls.doComplete(doc(['name: shop', '']), { line: 1, character: 0 }, false);
  const labels = top.items.map((i) => i.label);
  assert.ok(labels.includes('fespalier'), labels.join(' '));
  assert.ok(labels.includes('dependencies') || labels.includes('environment'), labels.join(' '));
  const inside = await ls.doComplete(doc(['name: shop', 'fespalier:', '  main: auto', '  ']), { line: 3, character: 2 }, false);
  const keys = inside.items.map((i) => i.label);
  for (const key of ['app_dir', 'adapters', 'tasks', 'telemetry']) {
    assert.ok(keys.includes(key), keys.join(' '));
  }
  assert.ok(!keys.includes('main'), 'a key already there is not offered again');
  const hover = await ls.doHover(doc(PUBSPEC), { line: 5, character: 4 });
  assert.match(JSON.stringify(hover?.contents), /fresh state because its URL changed/);
});

test("when the store's schema cannot load, the server says so, as it does without this extension", async () => {
  const without = await problems(service(false, false), doc(PUBSPEC));
  const withOurs = await problems(service(true, false), doc(PUBSPEC));
  assert.equal(without.length, 1);
  assert.equal(withOurs.length, 1);
  assert.match(withOurs[0], /^1: .*https:\/\/www\.schemastore\.org\/pubspec\.json/);
});
