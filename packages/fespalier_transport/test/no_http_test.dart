// The point of this package: an interface that links neither package:http nor Dio, so an auth
// package that sends through it does not either. This reads lib/ and the pubspec and fails on the
// import or the dependency that would break that.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The import directives in [lines] that name a package in [banned].
List<String> bannedImports(
  String path,
  List<String> lines,
  List<String> banned,
) {
  final problems = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimLeft();
    if (!line.startsWith('import ') && !line.startsWith('export ')) continue;
    for (final prefix in banned) {
      if (line.contains("'package:$prefix") ||
          line.contains('"package:$prefix')) {
        problems.add('$path:${i + 1}: $line');
      }
    }
  }
  return problems;
}

/// The entries of the top-level `dependencies:` section of [pubspec].
List<String> dependenciesOf(List<String> pubspec) {
  final entries = <String>[];
  var inside = false;
  for (final line in pubspec) {
    if (line.startsWith('dependencies:')) {
      inside = true;
      continue;
    }
    if (!inside) continue;
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ')) break; // the next top-level key
    if (line.startsWith('  ') && !line.startsWith('   ')) {
      entries.add(line.trim());
    }
  }
  return entries;
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
        ...bannedImports(file.path, file.readAsLinesSync(), [
          'http/',
          'dio/',
          'dio.dart',
        ]),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the pubspec lists no dependency at all', () {
    final dependencies = dependenciesOf(File('pubspec.yaml').readAsLinesSync());
    expect(dependencies, isEmpty, reason: 'found: $dependencies');
  });

  test('the checks catch what they are for', () {
    expect(
      bannedImports(
        'f.dart',
        ["import 'package:http/http.dart' as http;"],
        ['http/'],
      ),
      hasLength(1),
    );
    expect(
      bannedImports('f.dart', ["export 'package:dio/dio.dart';"], ['dio/']),
      hasLength(1),
    );
    expect(
      bannedImports(
        'f.dart',
        ["import 'dart:async';", "import 'src/x.dart';", '// package:http/'],
        ['http/'],
      ),
      isEmpty,
    );
    expect(
      dependenciesOf([
        'name: x',
        'dependencies:',
        '  http: ^1.0.0',
        '',
        'dev_dependencies:',
        '  a: 1',
      ]),
      ['http: ^1.0.0'],
    );
    expect(
      dependenciesOf([
        'dependencies:',
        '  # a comment',
        'dev_dependencies:',
        '  flutter_test:',
        '    sdk: flutter',
      ]),
      isEmpty,
    );
    expect(
      dependenciesOf([
        'dependencies:',
        '  fespalier:',
        '    git:',
        '      url: x',
        '  http: ^1',
      ]),
      ['fespalier:', 'http: ^1'],
    );
  });
}
