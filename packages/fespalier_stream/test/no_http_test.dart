// Everything that sends HTTP sends through fespalier_transport: an event stream is a request like
// any other, so the app's decorators (a session, a signature, a trace) apply to it, and the app
// chooses the client. This reads lib/ and the pubspec and fails on the import or the dependency
// that would undo that. Not even a test uses package:http or Dio here: the fakes are transports.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The packages lib/ must not import and the pubspec must not list.
const banned = <String>[
  'http',
  'dio',
  'dio_web_adapter',
  'fespalier_http',
  'fespalier_dio',
];

/// The import and export directives in [lines] that name a package in [names].
List<String> bannedImports(
  String path,
  List<String> lines,
  List<String> names,
) {
  final problems = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimLeft();
    if (!line.startsWith('import ') && !line.startsWith('export ')) continue;
    for (final name in names) {
      if (line.contains("'package:$name/") ||
          line.contains('"package:$name/')) {
        problems.add('$path:${i + 1}: $line');
      }
    }
  }
  return problems;
}

/// The names under the top-level [section] (`dependencies` or `dev_dependencies`) of [pubspec].
List<String> namesIn(List<String> pubspec, String section) {
  final names = <String>[];
  var inside = false;
  for (final line in pubspec) {
    if (line.startsWith('$section:')) {
      inside = true;
      continue;
    }
    if (!inside) continue;
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ')) break; // the next top-level key
    if (line.startsWith('  ') && !line.startsWith('   ')) {
      names.add(line.trim().split(':').first);
    }
  }
  return names;
}

void main() {
  test(
    'no file under lib/ imports package:http, Dio or their fespalier wrappers',
    () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);
      final problems = [
        for (final file in files)
          ...bannedImports(file.path, file.readAsLinesSync(), banned),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  test('the pubspec lists none of them, as a dependency or a dev one', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    expect(namesIn(pubspec, 'dependencies'), contains('fespalier_transport'));
    final found = [
      ...namesIn(pubspec, 'dependencies'),
      ...namesIn(pubspec, 'dev_dependencies'),
    ].where(banned.contains).toList();
    expect(found, isEmpty, reason: 'found: $found');
  });

  test('the checks catch what they are for', () {
    expect(
      bannedImports('f.dart', [
        "import 'package:http/http.dart' as http;",
      ], banned),
      hasLength(1),
    );
    expect(
      bannedImports('f.dart', ["export 'package:dio/dio.dart';"], banned),
      hasLength(1),
    );
    expect(
      bannedImports('f.dart', [
        "import 'package:fespalier_http/fespalier_http.dart';",
      ], banned),
      hasLength(1),
    );
    expect(
      bannedImports('f.dart', [
        "import 'dart:async';",
        "import 'package:fespalier_transport/fespalier_transport.dart';",
        '// package:http/',
      ], banned),
      isEmpty,
    );
    const pubspec = [
      'name: x',
      'dependencies:',
      '  http: ^1.0.0',
      '  fespalier:',
      '    git:',
      '      url: x',
      '',
      'dev_dependencies:',
      '  dio: 1',
      '  flutter_test:',
      '    sdk: flutter',
    ];
    expect(namesIn(pubspec, 'dependencies'), ['http', 'fespalier']);
    expect(namesIn(pubspec, 'dev_dependencies'), ['dio', 'flutter_test']);
  });
}
