// The point of the generated client being `--preset fespalier`: it sends through fespalier's
// `HttpTransport`, so nothing in this example or in the client links Dio, and `package:http` is named
// in one place only, `startup()`, where the app's one transport is built over it. This reads the
// sources and the pubspecs and fails on the import or the dependency that would undo that. (A test
// may use either: they are dev_dependencies.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Never, anywhere: Dio and its fespalier wrapper.
const dio = <String>[
  'dio',
  'dio_web_adapter',
  'fespalier_dio',
  'dio_smart_retry',
];

/// Only in `lib/app/startup.dart`: the client the transport is built over.
const http = <String>['http', 'fespalier_http'];

/// The import and export directives in [lines] that name a package in [names].
List<String> importsOf(String path, List<String> lines, List<String> names) {
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

/// The names under the top-level `dependencies:` section of [pubspec].
List<String> dependenciesOf(List<String> pubspec) {
  final names = <String>[];
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
      names.add(line.trim().split(':').first);
    }
  }
  return names;
}

List<File> dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  test(
    'no file of the app imports Dio, and only startup.dart imports package:http',
    () {
      final files = dartFiles('lib');
      expect(files, isNotEmpty);
      final dioImports = [
        for (final file in files)
          ...importsOf(file.path, file.readAsLinesSync(), dio),
      ];
      expect(dioImports, isEmpty, reason: dioImports.join('\n'));
      final httpImports = [
        for (final file in files.where(
          (f) => !f.path.endsWith('lib/app/startup.dart'),
        ))
          ...importsOf(file.path, file.readAsLinesSync(), http),
      ];
      expect(httpImports, isEmpty, reason: httpImports.join('\n'));
      final startup = File('lib/app/startup.dart').readAsLinesSync();
      expect(importsOf('startup.dart', startup, http), hasLength(2));
    },
  );

  test('no file of the generated client imports Dio or package:http', () {
    final files = dartFiles('client/lib');
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        ...importsOf(file.path, file.readAsLinesSync(), [...dio, ...http]),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test(
    'neither pubspec lists Dio, and the client lists no HTTP client at all',
    () {
      final app = dependenciesOf(File('pubspec.yaml').readAsLinesSync());
      expect(app.where(dio.contains), isEmpty, reason: 'app: $app');
      final client = dependenciesOf(
        File('client/pubspec.yaml').readAsLinesSync(),
      );
      expect(
        client.where([...dio, ...http].contains),
        isEmpty,
        reason: 'client: $client',
      );
      expect(client, contains('fespalier_transport'));
    },
  );

  test('Dio is nowhere in the resolved dependency graph', () {
    final config = File('.dart_tool/package_config.json');
    if (!config.existsSync()) {
      markTestSkipped('no .dart_tool/package_config.json: run flutter pub get');
      return;
    }
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    final names = [for (final p in packages) (p as Map)['name'] as String];
    expect(names, contains('orders_client'));
    expect(names.where(dio.contains), isEmpty);
  });

  test('the checks catch what they are for', () {
    expect(
      importsOf('f.dart', ["import 'package:dio/dio.dart';"], dio),
      hasLength(1),
    );
    expect(
      importsOf('f.dart', [
        "export 'package:fespalier_http/fespalier_http.dart';",
      ], http),
      hasLength(1),
    );
    expect(
      importsOf(
        'f.dart',
        [
          "import 'package:fespalier_transport/fespalier_transport.dart';",
          '// package:http/',
        ],
        [...dio, ...http],
      ),
      isEmpty,
    );
    expect(
      dependenciesOf([
        'dependencies:',
        '  http: ^1.0.0',
        '  orders_client:',
        '    path: client',
        'dev_dependencies:',
        '  dio: 1',
      ]),
      ['http', 'orders_client'],
    );
  });
}
