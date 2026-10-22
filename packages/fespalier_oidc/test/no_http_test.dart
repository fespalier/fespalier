// The rule, in code: fespalier_oidc sends only through `package:fespalier_transport`'s
// `HttpTransport`, so it links neither `package:http` nor Dio (an app that signs in with Dio
// does not pull `package:http`, and the other way round). This reads every file under lib/ and
// the dependencies of pubspec.yaml and fails on the first import or entry that would break it.
// Dev dependencies are free: a test may use whatever it needs, and does not use these two
// (they are not dev dependencies either).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The packages the library must not depend on, and why.
const forbidden = <String, String>{
  'http': 'package:http is fespalier_http\'s transport, not this package\'s',
  'dio': 'Dio is fespalier_dio\'s transport, not this package\'s',
  'fespalier_http': 'the HTTP transport is the app\'s to choose',
  'fespalier_dio': 'the Dio transport is the app\'s to choose',
};

/// The `import`/`export` lines of [source] that name a [forbidden] package, as `line: text`.
List<String> forbiddenImports(String source) {
  final problems = <String>[];
  final lines = source.split('\n');
  final directive = RegExp(
    r'''^\s*(?:import|export)\s+['"]package:([a-z0-9_]+)/''',
  );
  for (var i = 0; i < lines.length; i++) {
    final name = directive.firstMatch(lines[i])?.group(1);
    if (name != null && forbidden.containsKey(name)) {
      problems.add('${i + 1}: ${lines[i].trim()}');
    }
  }
  return problems;
}

/// The entries of the top-level section [section] of a pubspec ([dependencies] or
/// [dev_dependencies]): the package names at its first indentation level.
List<String> pubspecEntries(String pubspec, String section) {
  final names = <String>[];
  var inside = false;
  for (final line in pubspec.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final topLevel = !line.startsWith(' ') && !line.startsWith('\t');
    if (topLevel) {
      inside = line.trimRight() == '$section:';
      continue;
    }
    if (!inside) continue;
    final entry = RegExp(r'^  ([A-Za-z0-9_]+):').firstMatch(line);
    if (entry != null) names.add(entry.group(1)!);
  }
  return names;
}

List<File> dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  test('no file under lib/ imports package:http or package:dio', () {
    final files = dartFiles('lib');
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        for (final found in forbiddenImports(file.readAsStringSync()))
          '${file.path}:$found',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('no test imports them either: they are not even dev dependencies', () {
    final files = dartFiles('test');
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        for (final found in forbiddenImports(file.readAsStringSync()))
          '${file.path}:$found',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('pubspec.yaml lists neither http nor dio under dependencies:', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final dependencies = pubspecEntries(pubspec, 'dependencies');
    expect(
      dependencies,
      containsAll(<String>[
        'fespalier',
        'fespalier_auth',
        'fespalier_transport',
      ]),
      reason: 'the parser sees the section',
    );
    final problems = [
      for (final name in dependencies)
        if (forbidden.containsKey(name)) '$name: ${forbidden[name]}',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('nor under dev_dependencies:', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final dev = pubspecEntries(pubspec, 'dev_dependencies');
    expect(dev, contains('flutter_test'));
    expect(dev.where(forbidden.containsKey), isEmpty);
  });

  test('the import check sees each directive, and only those', () {
    for (final line in [
      "import 'package:http/http.dart' as http;",
      'import "package:http/testing.dart";',
      "export 'package:dio/dio.dart';",
      "  import 'package:dio/dio.dart';",
      "import 'package:fespalier_http/fespalier_http.dart';",
      "import 'package:fespalier_dio/fespalier_dio.dart' show DioTransport;",
    ]) {
      expect(forbiddenImports(line), hasLength(1), reason: line);
    }
    for (final line in [
      "import 'package:fespalier_transport/fespalier_transport.dart';",
      "import 'package:http_parser/http_parser.dart';",
      "import 'package:dio_smart_retry/dio_smart_retry.dart';",
      "// import 'package:http/http.dart';",
      "final s = 'import package:http/http.dart';",
      "import 'dart:io';",
    ]) {
      expect(forbiddenImports(line), isEmpty, reason: line);
    }
    expect(
      forbiddenImports("import 'dart:io';\nimport 'package:http/http.dart';"),
      ['2: import \'package:http/http.dart\';'],
    );
  });

  test('the pubspec reader sees a section\'s entries, and only its own', () {
    const pubspec = '''
name: x
dependencies:
  # a comment
  clock: ^1.1.1
  http: ^1.0.0
  fespalier:
    git:
      url: https://example.com/x
      ref: v1
dev_dependencies:
  dio: ^5.0.0
  flutter_test:
    sdk: flutter
environment:
  sdk: ^3.9.0
''';
    expect(pubspecEntries(pubspec, 'dependencies'), [
      'clock',
      'http',
      'fespalier',
    ]);
    expect(pubspecEntries(pubspec, 'dev_dependencies'), [
      'dio',
      'flutter_test',
    ]);
    expect(pubspecEntries(pubspec, 'dependency_overrides'), isEmpty);
  });
}
