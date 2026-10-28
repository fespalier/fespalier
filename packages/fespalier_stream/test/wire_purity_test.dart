// The wire layer (the decoder, the statuses, the connection) is plain Dart over
// fespalier_transport: no Flutter, no Riverpod, no fespalier, so it could run on a server or in a
// pure Dart isolate, and so the rules it follows (no timer, the abort trigger) are read without a
// framework around them. This reads every import of lib/src/wire/ and fails on another one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What a wire file may import: the Dart SDK, the transport, the clock and its own folder.
bool allowed(String uri) =>
    uri.startsWith('dart:') &&
        !const {
          'dart:ui',
          'dart:io',
          'dart:html',
          'dart:js_interop',
        }.contains(uri) ||
    uri.startsWith('package:fespalier_transport/') ||
    uri.startsWith('package:clock/') ||
    (!uri.contains(':') && !uri.contains('/'));

/// The import, export and part directives of [lines] that name what [allowed] refuses.
List<String> impure(String path, List<String> lines) {
  final directive = RegExp(r'''^\s*(import|export|part)\s+['"]([^'"]+)['"]''');
  return [
    for (var i = 0; i < lines.length; i++)
      if (directive.firstMatch(lines[i]) case final m?
          when !allowed(m.group(2)!))
        '$path:${i + 1}: ${lines[i].trim()}',
  ];
}

void main() {
  test('lib/src/wire imports only dart:, fespalier_transport and clock', () {
    final files = Directory('lib/src/wire')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, hasLength(greaterThanOrEqualTo(5)));
    final problems = [
      for (final file in files) ...impure(file.path, file.readAsLinesSync()),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the check refuses what it is for', () {
    for (final line in [
      "import 'package:flutter/foundation.dart';",
      "import 'package:fespalier/fespalier.dart' show DataRefusal;",
      "import 'package:riverpod/riverpod.dart';",
      "import 'dart:ui';",
      "import 'dart:io';",
      "import '../telemetry.dart';",
      "export 'package:hooks_riverpod/hooks_riverpod.dart';",
    ]) {
      expect(impure('f.dart', [line]), hasLength(1), reason: line);
    }
    for (final line in [
      "import 'dart:async';",
      "import 'dart:convert';",
      "import 'package:clock/clock.dart';",
      "import 'package:fespalier_transport/fespalier_transport.dart';",
      "import 'live_status.dart';",
      '// import package:flutter/foundation.dart',
    ]) {
      expect(impure('f.dart', [line]), isEmpty, reason: line);
    }
  });
}
