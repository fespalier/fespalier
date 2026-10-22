// fespalier_dio is Dio's side of package:fespalier_transport and links no package:http: an app
// that uses Dio links none of it. This reads lib/ and pubspec.yaml and fails on an import of
// package:http or package:fespalier_http, or a dependency on either.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _forbiddenImport = RegExp(
  r'''^\s*(import|export)\s+['"]package:(http|fespalier_http)/''',
);

/// The imports and exports of package:http or package:fespalier_http in [lines].
List<String> httpImports(String path, List<String> lines) => [
  for (var i = 0; i < lines.length; i++)
    if (_forbiddenImport.hasMatch(lines[i]))
      '$path:${i + 1}: ${lines[i].trim()}',
];

/// The `dependencies:` entries of a pubspec's [lines] that are http or fespalier_http.
List<String> httpDependencies(List<String> lines) {
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
    if (match != null && const {'http', 'fespalier_http'}.contains(match[1])) {
      found.add(match[1]!);
    }
  }
  return found;
}

void main() {
  test('no file under lib/ imports package:http or package:fespalier_http', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        ...httpImports(file.path, file.readAsLinesSync()),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('pubspec.yaml does not depend on http or fespalier_http', () {
    final found = httpDependencies(File('pubspec.yaml').readAsLinesSync());
    expect(found, isEmpty, reason: 'dependencies: lists $found');
  });

  test(
    'the check catches each import and dependency, and ignores the rest',
    () {
      expect(
        httpImports('f.dart', [
          "import 'package:http/http.dart' as http;",
          "export 'package:fespalier_http/problem.dart';",
          "import 'package:fespalier_transport/fespalier_transport.dart';",
          "// import 'package:http/http.dart';",
        ]),
        hasLength(2),
      );
      expect(
        httpDependencies([
          'dependencies:',
          '  dio: ^5.7.0',
          '  http: ^1.5.0',
          '  fespalier_http:',
          '    git:',
          'dev_dependencies:',
          '  http: ^1.0.0',
        ]),
        ['http', 'fespalier_http'],
      );
    },
  );
}
