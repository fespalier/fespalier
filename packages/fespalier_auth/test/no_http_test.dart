// The core sends only through fespalier_transport's HttpTransport: it links neither package:http
// nor Dio. Those belong to fespalier_http and fespalier_dio, which implement the transport.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The imports of [source] that name a package in [banned], as `import ...;` lines.
List<String> bannedImports(String source, List<String> banned) => [
  for (final line in source.split('\n'))
    if (RegExp(
          r'''^\s*(?:import|export)\s+['"]package:(\w+)/''',
        ).firstMatch(line)
        case final match?)
      if (banned.contains(match.group(1))) line.trim(),
];

/// The package names the `dependencies:` section of [pubspec] lists (dev dependencies and the
/// rest are other sections).
List<String> dependencies(String pubspec) {
  final names = <String>[];
  var inside = false;
  for (final line in pubspec.split('\n')) {
    if (line.startsWith('#')) continue;
    if (RegExp(r'^\S').hasMatch(line)) {
      inside = line.startsWith('dependencies:');
      continue;
    }
    if (!inside) continue;
    final match = RegExp(r'^  (\w+):').firstMatch(line);
    if (match != null) names.add(match.group(1)!);
  }
  return names;
}

void main() {
  const banned = ['http', 'dio'];

  test('no file under lib/ imports package:http or package:dio', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        for (final line in bannedImports(file.readAsStringSync(), banned))
          '${file.path}: $line',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('pubspec.yaml lists neither http nor dio under dependencies', () {
    final listed = dependencies(File('pubspec.yaml').readAsStringSync());
    expect(listed, contains('fespalier_transport'));
    expect(listed.where(banned.contains), isEmpty);
  });

  test('the checks see what they are meant to see', () {
    expect(
      bannedImports(
        "import 'package:http/http.dart' as http;\n"
        'import "package:dio/dio.dart";\n'
        "export 'package:http/retry.dart';\n"
        "import 'package:http_parser/http_parser.dart';\n"
        "import 'package:fespalier_http/fespalier_http.dart';\n"
        "// import 'package:http/http.dart';\n",
        banned,
      ),
      hasLength(3),
    );
    const pubspec = '''
name: x
dependencies:
  clock: ^1.1.1
  flutter:
    sdk: flutter
  http: ^1.0.0
dev_dependencies:
  dio: ^5.0.0
  flutter_test:
    sdk: flutter
''';
    expect(dependencies(pubspec), ['clock', 'flutter', 'http']);
  });
}
