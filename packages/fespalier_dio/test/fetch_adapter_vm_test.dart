// package:fespalier_dio/fetch.dart outside a browser (since 0.25.0): webStreamingAdapter is Dio's
// default adapter, FetchHttpClientAdapter exists so code shared with the web compiles, and only
// its fetch refuses. The browser side is test/browser/harness.dart (`just fetch-adapter`).
//
// It also reads the library's files: the conditional export picks the web file in a web build,
// both files offer the same names, the library imports neither Flutter nor fespalier (a web entry
// point compiles it alone), and the body is not read by an `async*` loop.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fespalier_dio/fetch.dart';
import 'package:flutter_test/flutter_test.dart';

/// The library's files: lib/fetch.dart and lib/src/fetch/.
List<File> libraryFiles() => [
  File('lib/fetch.dart'),
  ...Directory(
    'lib/src/fetch',
  ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart')),
];

/// What a file of the library may import: the Dart SDK (no dart:ui), Dio, package:web and itself.
bool allowed(String uri) =>
    (uri.startsWith('dart:') && uri != 'dart:ui') ||
    uri.startsWith('package:dio/') ||
    uri.startsWith('package:web/') ||
    !uri.contains(':');

/// The directives of [lines] that name what [allowed] refuses.
List<String> foreign(String path, List<String> lines) {
  final directive = RegExp(
    r'''^\s*(?:import|export|if\s*\([^)]*\))\s*['"]([^'"]+)['"]''',
  );
  return [
    for (var i = 0; i < lines.length; i++)
      if (directive.firstMatch(lines[i]) case final m?
          when !allowed(m.group(1)!))
        '$path:${i + 1}: ${lines[i].trim()}',
  ];
}

/// The public top-level names a file declares.
Set<String> publicNames(String source) => {
  for (final m in RegExp(
    r'^(?:final class|class|HttpClientAdapter) ([A-Za-z]\w*)',
    multiLine: true,
  ).allMatches(source))
    m.group(1)!,
};

void main() {
  test('webStreamingAdapter is Dio\'s default adapter outside a browser', () {
    expect(webStreamingAdapter(), isA<IOHttpClientAdapter>());
    expect(
      webStreamingAdapter(withCredentials: true),
      isA<IOHttpClientAdapter>(),
    );
  });

  test('FetchHttpClientAdapter is there, and refuses to fetch', () async {
    final adapter = FetchHttpClientAdapter();
    expect(adapter.withCredentials, isFalse);
    expect(
      FetchHttpClientAdapter(withCredentials: true).withCredentials,
      isTrue,
    );
    expect(
      () => adapter.fetch(
        RequestOptions(path: 'https://example.com/'),
        null,
        null,
      ),
      throwsUnsupportedError,
    );
    adapter.close(force: true);

    final dio = Dio()..httpClientAdapter = FetchHttpClientAdapter();
    await expectLater(
      dio.get<String>('https://example.com/'),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'error',
          isA<UnsupportedError>(),
        ),
      ),
    );
  });

  test('the conditional export takes the web file where js_interop is', () {
    final library = File('lib/fetch.dart').readAsStringSync();
    expect(
      library,
      contains(
        "export 'src/fetch/fetch_adapter_stub.dart'\n"
        "    if (dart.library.js_interop) 'src/fetch/fetch_adapter_web.dart'\n"
        '    show FetchHttpClientAdapter, webStreamingAdapter;',
      ),
    );
    final stub = File(
      'lib/src/fetch/fetch_adapter_stub.dart',
    ).readAsStringSync();
    final web = File('lib/src/fetch/fetch_adapter_web.dart').readAsStringSync();
    expect(publicNames(stub), {
      'FetchHttpClientAdapter',
      'webStreamingAdapter',
    });
    expect(publicNames(web), publicNames(stub));
  });

  test('the library imports only the SDK, Dio and package:web', () {
    final files = libraryFiles();
    expect(files, hasLength(3));
    final problems = [
      for (final file in files) ...foreign(file.path, file.readAsLinesSync()),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the check refuses what it is for', () {
    for (final line in [
      "import 'package:fespalier/fespalier.dart';",
      "import 'package:flutter/foundation.dart';",
      "import 'package:fespalier_transport/fespalier_transport.dart';",
      "import 'dart:ui';",
      "    if (dart.library.io) 'package:fespalier/x.dart'",
    ]) {
      expect(foreign('f.dart', [line]), hasLength(1), reason: line);
    }
    for (final line in [
      "import 'dart:js_interop';",
      "import 'package:dio/dio.dart';",
      "import 'package:web/web.dart' as web;",
      "export 'src/fetch/fetch_adapter_stub.dart'",
      "    if (dart.library.js_interop) 'src/fetch/fetch_adapter_web.dart'",
    ]) {
      expect(foreign('f.dart', [line]), isEmpty, reason: line);
    }
  });

  test('the body is read by a pump, not an async* loop', () {
    // An async* generator runs its cleanup (the abort) only when its next chunk arrives, so an
    // event stream that is quiet would stay open after its subscription was cancelled.
    final web = File('lib/src/fetch/fetch_adapter_web.dart').readAsStringSync();
    expect(web, isNot(matches(RegExp(r'\)\s*async\*\s*\{'))));
    expect(web, contains('onCancel: request.abort'));
  });
}
