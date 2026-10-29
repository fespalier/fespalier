// The library split (since 0.25.0): an app that opens no WebSocket imports no package:web_socket.
// package:fespalier_stream/fespalier_stream.dart reaches none of lib/src/socket/ and none of
// package:web_socket; lib/web_socket.dart does, through the connector's files alone, and dart:io only
// behind the conditional import a web build never takes. The rest of the socket folder is pure Dart
// over fespalier_transport and clock (only the two files that need fespalier import it), so the
// browser harness of `just fetch-adapter` compiles it without Flutter. This reads the imports.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final directive = RegExp(
  r'''^\s*(import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Every URI [file] imports, exports or parts, conditional ones included.
List<String> urisOf(File file) {
  final text = file.readAsStringSync();
  final uris = [for (final m in directive.allMatches(text)) m.group(2)!];
  // `import 'a.dart' if (dart.library.io) 'b.dart'`: the conditional URIs too.
  final conditional = RegExp(r'''if\s*\([^)]*\)\s*['"]([^'"]+)['"]''');
  uris.addAll([for (final m in conditional.allMatches(text)) m.group(1)!]);
  return uris;
}

/// The files of lib/ that [entry] reaches, itself included, and the outside URIs they name.
({Set<String> files, Set<String> outside}) reach(String entry) {
  final files = <String>{};
  final outside = <String>{};
  final todo = [File(entry).absolute.path];
  while (todo.isNotEmpty) {
    final path = todo.removeLast();
    if (!files.add(path)) continue;
    for (final uri in urisOf(File(path))) {
      if (uri.startsWith('package:fespalier_stream/')) {
        todo.add(
          File(
            'lib/${uri.substring('package:fespalier_stream/'.length)}',
          ).absolute.path,
        );
      } else if (uri.contains(':')) {
        outside.add(uri);
      } else {
        todo.add(File(path).parent.uri.resolve(uri).toFilePath());
      }
    }
  }
  return (files: files, outside: outside);
}

String local(String path) =>
    path.substring(Directory('lib').absolute.path.length - 3);

void main() {
  test('the main library reaches no socket file and no package:web_socket', () {
    final main = reach('lib/fespalier_stream.dart');
    expect(main.files.map(local).where((f) => f.contains('/socket/')), isEmpty);
    expect(
      main.outside.where((uri) => uri.startsWith('package:web_socket')),
      isEmpty,
    );
    expect(main.outside, isNot(contains('dart:io')));
  });

  test('lib/web_socket.dart reaches package:web_socket', () {
    final sockets = reach('lib/web_socket.dart');
    expect(sockets.outside, contains('package:web_socket/web_socket.dart'));
  });

  test(
    'only the connector files and the socket library import package:web_socket, and dart:io only in its io one',
    () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      final webSocket = <String>{};
      final io = <String>{};
      for (final file in files) {
        final uris = urisOf(file);
        if (uris.any((u) => u.startsWith('package:web_socket/'))) {
          webSocket.add(local(file.absolute.path));
        }
        if (uris.contains('dart:io')) io.add(local(file.absolute.path));
      }
      expect(webSocket, {
        // It re-exports the two exceptions a socket throws, so an app imports no web_socket.
        'lib/web_socket.dart',
        'lib/src/socket/web_socket_connector.dart',
        'lib/src/socket/web_socket_open.dart',
        'lib/src/socket/web_socket_open_io.dart',
      });
      expect(io, {'lib/src/socket/web_socket_open_io.dart'});
    },
  );

  test('the socket folder is pure Dart but for its fespalier files', () {
    const fespalier = {'socket_connection.dart', 'ticket.dart'};
    final problems = <String>[];
    for (final file in Directory(
      'lib/src/socket',
    ).listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (fespalier.contains(name)) continue;
      for (final uri in urisOf(file)) {
        final ok =
            (uri.startsWith('dart:') &&
                !const {'dart:ui', 'dart:html'}.contains(uri)) ||
            uri.startsWith('package:fespalier_transport/') ||
            uri.startsWith('package:clock/') ||
            uri.startsWith('package:web_socket/') ||
            uri == '../wire/event_source.dart' ||
            uri == '../wire/live_connection.dart' ||
            uri == '../wire/live_status.dart' ||
            (!uri.contains(':') && !uri.contains('/'));
        if (!ok) problems.add('$name: $uri');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
