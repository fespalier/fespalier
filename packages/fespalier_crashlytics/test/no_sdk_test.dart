// The package depends on no Firebase package, on purpose (decision 1 of the 0.18.0 plan, and the
// pubspec's comment): every Firebase plugin of an app shares one firebase_core major, and a range in
// a git-pinned companion would hold them all back at each Firebase major until fespalier ships. The
// binding is a compiled recipe in skills/fespalier-observability/references/crashlytics.md, which
// `just skill-samples` builds in a scratch app. This reads the package's own files and fails on a
// Firebase name, and on any import in lib/ that is not the Dart SDK, Flutter, fespalier, clock or the
// package's own files.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Firebase names a file of this package may not have: the packages and their libraries, in
/// lowercase (the prose says `Firebase`, capitalised, and is allowed).
const String firebaseName = 'firebase';

/// Whether an import or export of `lib/` may name [uri]: the Dart SDK, Flutter, fespalier, clock, or
/// a file of this package (relative).
bool allowedImport(String uri) =>
    uri.startsWith('dart:') ||
    uri.startsWith('package:flutter/') ||
    uri.startsWith('package:fespalier/') ||
    uri.startsWith('package:clock/') ||
    !uri.contains(':');

/// Every URI a Dart file imports or exports, in order.
Iterable<String> importsOf(String text) sync* {
  final directive = RegExp(
    r"^\s*(?:import|export)\s+'([^']+)'",
    multiLine: true,
  );
  for (final match in directive.allMatches(text)) {
    yield match.group(1)!;
  }
}

void main() {
  test('pubspec.yaml names no Firebase package', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains(firebaseName)));
  });

  test('no file under lib/ names a Firebase package', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    for (final file in files) {
      expect(
        file.readAsStringSync(),
        isNot(contains(firebaseName)),
        reason: file.path,
      );
    }
  });

  test('every import and export in lib/ is the Dart SDK, Flutter, fespalier, '
      'clock or a file of the package', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    final problems = [
      for (final file in files)
        for (final uri in importsOf(file.readAsStringSync()))
          if (!allowedImport(uri)) '${file.path}: $uri',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the check refuses a Firebase import, and takes the SDK and the '
      'package', () {
    expect(
      importsOf("import 'package:firebase_core/firebase_core.dart';").toList(),
      ['package:firebase_core/firebase_core.dart'],
    );
    expect(
      allowedImport('package:firebase_crashlytics/firebase_crashlytics.dart'),
      isFalse,
    );
    for (final uri in [
      'dart:async',
      'package:flutter/foundation.dart',
      'package:fespalier/fespalier.dart',
      'package:clock/clock.dart',
      'src/reporter.dart',
    ]) {
      expect(allowedImport(uri), isTrue, reason: uri);
    }
  });
}
