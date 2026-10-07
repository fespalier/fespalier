// The rule, in code: no Tolgee API key in a release build. The key is read in one file, in a
// ternary guarded by kTolgeeInContext, which the compiler folds to '' in release. TolgeeCdn takes
// no key, and nothing else in lib/ names the define.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, String> _lib() => {
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
    if (f.path.endsWith('.dart')) f.path: f.readAsStringSync(),
};

/// A call of `fromEnvironment` that names the key, whatever the quotes and the line breaks.
final _read = RegExp(r'''fromEnvironment\(\s*['"]TOLGEE_API_KEY''');

/// The one allowed shape: `const x = kTolgeeInContext ? String.fromEnvironment('TOLGEE_API_KEY') : '';`
final _guarded = RegExp(
  r'''const\s+\w+\s*=\s*kTolgeeInContext\s*\?\s*String\.fromEnvironment\(\s*['"]TOLGEE_API_KEY['"]\s*,?\s*\)\s*:\s*['"]{2}\s*;''',
);

/// Lines that are code: the comments are not.
String _code(String source) => source
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .map((l) => l.split(' // ').first)
    .join('\n');

/// The files that read the key by `fromEnvironment`.
List<String> readers(Map<String, String> files) => [
  for (final MapEntry(:key, :value) in files.entries)
    if (_read.hasMatch(_code(value))) key,
];

void main() {
  final files = _lib();

  test('the key is read in one file, in a ternary behind kTolgeeInContext', () {
    final reads = readers(files);
    expect(reads, hasLength(1), reason: reads.join(', '));
    expect(reads.single, endsWith('editor.dart'));
    expect(_guarded.hasMatch(_code(files[reads.single]!)), isTrue);
    expect(_read.allMatches(_code(files[reads.single]!)), hasLength(1));
  });

  test('the name of the define appears in no other file of lib/', () {
    for (final MapEntry(:key, :value) in files.entries) {
      if (key.endsWith('editor.dart')) continue;
      expect(_code(value), isNot(contains('TOLGEE_API_KEY')), reason: key);
    }
  });

  test('no Tolgee key literal in lib/', () {
    for (final MapEntry(:key, :value) in files.entries) {
      expect(value, isNot(contains('tgpak_')), reason: key);
      expect(value, isNot(contains('tgpat_')), reason: key);
    }
  });

  test("TolgeeCdn's constructor has no key, token or secret parameter", () {
    final source = File('lib/src/tolgee_cdn.dart').readAsStringSync();
    final start = source.indexOf('TolgeeCdn(');
    final end = source.indexOf(');', start);
    final ctor = source.substring(start, end).toLowerCase();
    for (final word in ['key', 'token', 'secret', 'authorization']) {
      expect(ctor, isNot(contains(word)));
    }
    expect(source.toLowerCase(), isNot(contains('x-api-key')));
    expect(source.toLowerCase(), isNot(contains('authorization')));
  });

  test("TolgeeEditor's only key-taking constructor is @visibleForTesting", () {
    final source = File('lib/src/in_context/editor.dart').readAsLinesSync();
    final i = source.indexWhere((l) => l.contains('TolgeeEditor.withKey('));
    expect(i, greaterThan(0));
    expect(source[i - 1].trim(), '@visibleForTesting');
    final publicKey = source.where(
      (l) => RegExp(r'^\s*TolgeeEditor\.[a-zA-Z]\w*\(.*[kK]ey').hasMatch(l),
    );
    expect(publicKey, hasLength(1));
  });

  test('the checks catch the shapes they are for', () {
    const wrapped = '''
const k = kTolgeeInContext
    ? String.fromEnvironment(
        'TOLGEE_API_KEY',
      )
    : '';
''';
    expect(_guarded.hasMatch(wrapped), isTrue);
    expect(
      readers({
        'a.dart': wrapped,
        'b.dart': 'const k = String.fromEnvironment("TOLGEE_API_KEY");',
        'c.dart': "const k = String.fromEnvironment(\n  'TOLGEE_API_KEY');",
        'd.dart': "// String.fromEnvironment('TOLGEE_API_KEY')",
      }),
      ['a.dart', 'b.dart', 'c.dart'],
    );
    expect(
      _guarded.hasMatch("const k = String.fromEnvironment('TOLGEE_API_KEY');"),
      isFalse,
    );
  });
}
