// The rule, in code: no Tolgee API key in a release build. The key is read in one file, on a line
// guarded by kTolgeeInContext, which the compiler folds to '' in release. TolgeeCdn takes no key.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<File> _lib() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

/// The files that read `TOLGEE_API_KEY`, and the lines that do it.
Map<String, List<String>> keyReads(Map<String, List<String>> files) => {
  for (final MapEntry(:key, :value) in files.entries)
    if (value.any((l) => l.contains("fromEnvironment('TOLGEE_API_KEY'")))
      key: value
          .where((l) => l.contains("fromEnvironment('TOLGEE_API_KEY'"))
          .toList(),
};

void main() {
  final files = {for (final f in _lib()) f.path: f.readAsLinesSync()};

  test('the key is read in one file, on a line behind kTolgeeInContext', () {
    final reads = keyReads(files);
    expect(reads.keys, hasLength(1), reason: reads.keys.join(', '));
    for (final line in reads.values.single) {
      expect(line, contains('kTolgeeInContext ?'));
    }
  });

  test('no Tolgee key literal in lib/', () {
    for (final MapEntry(:key, :value) in files.entries) {
      for (final line in value) {
        expect(line, isNot(contains('tgpak_')), reason: key);
        expect(line, isNot(contains('tgpat_')), reason: key);
      }
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
    expect(
      source.where((l) => l.contains('TolgeeEditor._(')).length,
      greaterThan(0),
    );
    // Nothing else takes a key: the private constructor is private.
    final publicKey = source.where(
      (l) => RegExp(r'^\s*TolgeeEditor\.[a-zA-Z]\w*\(.*[kK]ey').hasMatch(l),
    );
    expect(publicKey, hasLength(1));
  });

  test('the check catches a second file that reads the key', () {
    final reads = keyReads({
      'a.dart': [
        "const k = kTolgeeInContext ? String.fromEnvironment('TOLGEE_API_KEY') : '';",
      ],
      'b.dart': ["const k = String.fromEnvironment('TOLGEE_API_KEY');"],
    });
    expect(reads.keys, hasLength(2));
  });
}
