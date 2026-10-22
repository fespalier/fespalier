// fespalier_keypair holds keys and signers and links neither package:http nor Dio: an app that
// uses either (or neither) links the same package. This reads lib/ and pubspec.yaml and fails on
// an import of package:http or package:dio, or a dependency on either (a dev dependency is fine:
// a test may need one).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _forbiddenImport = RegExp(
  r'''^\s*(import|export)\s+['"]package:(http|dio)/''',
);

/// The imports and exports of package:http or package:dio in [lines].
List<String> forbiddenImports(String path, List<String> lines) => [
  for (var i = 0; i < lines.length; i++)
    if (_forbiddenImport.hasMatch(lines[i]))
      '$path:${i + 1}: ${lines[i].trim()}',
];

/// The `dependencies:` entries of a pubspec's [lines] that are http or dio.
List<String> forbiddenDependencies(List<String> lines) {
  final found = <String>[];
  var inDependencies = false;
  for (final line in lines) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indented = line.startsWith(' ');
    if (!indented) {
      inDependencies = line.trimRight() == 'dependencies:';
      continue;
    }
    if (!inDependencies) continue;
    // Only direct children of `dependencies:` (two spaces), not their git/path keys.
    final match = RegExp(r'^  (\w+):').firstMatch(line);
    if (match != null && const {'http', 'dio'}.contains(match[1])) {
      found.add(match[1]!);
    }
  }
  return found;
}

void main() {
  test('no file under lib/ imports package:http or package:dio', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        ...forbiddenImports(file.path, file.readAsLinesSync()),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('pubspec.yaml does not depend on http or dio in dependencies:', () {
    final found = forbiddenDependencies(File('pubspec.yaml').readAsLinesSync());
    expect(found, isEmpty, reason: 'dependencies: lists $found');
  });

  test(
    'no auth concept: lib/ and dependencies: name no other fespalier package',
    () {
      // Keys and signers only: a protocol (fespalier_keypair_dpop, fespalier_sign_keypair) builds on
      // this package, never the other way round.
      final imports = [
        for (final file in Directory(
          'lib',
        ).listSync(recursive: true).whereType<File>())
          for (final line in file.readAsLinesSync())
            if (RegExp(
              r'''^\s*(import|export)\s+['"]package:fespalier''',
            ).hasMatch(line))
              '${file.path}: ${line.trim()}',
      ];
      expect(imports, isEmpty, reason: imports.join('\n'));
      final dependencies = File('pubspec.yaml')
          .readAsLinesSync()
          .skipWhile((l) => l.trimRight() != 'dependencies:')
          .skip(1)
          .takeWhile((l) => l.startsWith(' ') || l.trim().isEmpty)
          .where((l) => RegExp(r'^  fespalier\w*:').hasMatch(l))
          .toList();
      expect(dependencies, isEmpty);
    },
  );

  test(
    'the check catches each import and dependency, and ignores the rest',
    () {
      expect(
        forbiddenImports('f.dart', [
          "import 'package:http/http.dart' as http;",
          "export 'package:dio/dio.dart';",
          "import 'package:fespalier_oidc/fespalier_oidc.dart';",
          "// import 'package:http/http.dart';",
        ]),
        hasLength(2),
      );
      expect(
        forbiddenDependencies([
          'dependencies:',
          '  clock: ^1.1.1',
          '  http: ^1.5.0',
          '  dio: ^5.7.0',
          '    git:',
          'dev_dependencies:',
          '  dio: ^5.7.0',
          '  http: ^1.0.0',
        ]),
        ['http', 'dio'],
      );
    },
  );
}
