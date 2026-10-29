// The server `just fetch-adapter` runs the browser harness against (test/browser/harness.dart).
//
//   dart run tool/stream_server.dart --root <dir> --ports <file> [--serve]
//
// It listens on two loopback ports, 0 each, and writes `{"page": A, "api": B, "dead": C}` to the
// ports file once both listen: the page and its compiled harness are served from A, the requests
// under test go to B (another origin, so every one of them is a CORS request, as an app's API
// is), and nothing listens on C (a request to it is never sent). It runs until it is killed.
//
// `--serve` (`just fetch-adapter-serve`, for a person with a browser CI does not have, Safari
// say) listens on every interface instead, so a phone on the same network can open the page, prints
// the URL of the page of each build for each address of this machine, and prints every log line
// (a connection that was closed, one that was ended) as it happens. CI never passes it.
//
// What B answers (A answers the same, and serves the files of --root):
//
// - `GET /sse?id=<id>`: `retry: 60000` and a comment, then ten events 200 ms apart, `id:` 1 to 10,
//   each carrying the time it was written (`{"i": n, "t": <ms since the epoch>}`), and the body
//   ends. Written on the raw socket, so a client that goes away is seen: the log gets
//   `closed <id> after <n>`, or `ended <id> after 10` when the server ended it.
// - `GET /slow?id=<id>`: the headers after 1.5 s (`closed <id> before headers` if the client left).
// - `GET /quiet?id=<id>`: the headers and a comment, nothing for 1.5 s, then one event whose data is
//   `late`, and the body ends (`closed <id> after <n>` if the client left, with n 0 or 1).
// - `GET /status?code=<n>`: that status with the reason phrase `Probe` and the body `status <n>`.
// - `POST /echo`: the request body, unchanged.
// - `GET /cors-star`: `ok`, with `access-control-allow-origin: *`, which a request that carries
//   credentials must refuse; every other answer names the caller's origin and allows credentials.
// - `GET /ws?id=<id>&ticket=<t>` (since 0.25.0): a WebSocket that picks the subprotocol `fsp.v1`
//   when offered and logs `ws-open <id> ticket=<t> protocol=<p>`, sends `hello` and the bytes 1, 2,
//   3, answers `echo:<x>` with `<x>`, bytes with the same bytes, and `close` by closing with 4001
//   and a reason; `ws-closed <id> code <n>` once it is closed, with the client's code.
// - `GET /log?id=<id>`: the log lines of that id, as JSON.
//
// Every answer exposes `x-fespalier-probe`. dart:io only: no package, no Flutter.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

final _log = <String>[];
var _verbose = false;

/// Adds [line] to the log the harness reads, and prints it with `--serve`.
void _record(String line) {
  _log.add(line);
  if (_verbose) {
    stdout.writeln('stream_server: ${DateTime.now().toIso8601String()} $line');
  }
}

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at < 0 || at + 1 >= args.length ? null : args[at + 1];
  }

  final root = Directory(option('--root') ?? '.');
  final portsFile = option('--ports');
  _verbose = args.contains('--serve');
  final address = _verbose
      ? InternetAddress.anyIPv4
      : InternetAddress.loopbackIPv4;
  final page = await HttpServer.bind(address, 0);
  final api = await HttpServer.bind(address, 0);
  final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final deadPort = dead.port;
  await dead.close();
  final ports = jsonEncode({
    'page': page.port,
    'api': api.port,
    'dead': deadPort,
  });
  if (portsFile != null) {
    // Written whole, then renamed: a reader never sees half of it.
    final temporary = File('$portsFile.tmp')..writeAsStringSync(ports);
    temporary.renameSync(portsFile);
  }
  stdout.writeln('stream_server: $ports');
  if (_verbose) await _printPages(page.port, api.port, deadPort);
  for (final server in [page, api]) {
    unawaited(
      server.forEach(
        (request) => unawaited(_handle(request, root, server == page)),
      ),
    );
  }
}

/// The URL of each build's page, for each address of this machine.
Future<void> _printPages(int page, int api, int dead) async {
  final hosts = <String>['127.0.0.1'];
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final address in interface.addresses) {
      if (!address.isLoopback) hosts.add(address.address);
    }
  }
  for (final host in hosts) {
    final query =
        'api=${Uri.encodeQueryComponent('http://$host:$api')}&dead=$dead&run=hand';
    stdout
      ..writeln(
        'stream_server: JavaScript: http://$host:$page/js/index.html?$query',
      )
      ..writeln(
        'stream_server: wasm:       http://$host:$page/wasm/index.html?$query',
      );
  }
  stdout.writeln(
    'stream_server: open a page, wait for its last line (all passed, or N failed); Ctrl+C stops.',
  );
}

Map<String, String> _cors(HttpRequest request, {bool star = false}) {
  final origin = request.headers.value('origin');
  final asked = request.headers.value('access-control-request-headers');
  return {
    if (star || origin == null)
      'access-control-allow-origin': '*'
    else ...{
      'access-control-allow-origin': origin,
      'access-control-allow-credentials': 'true',
      'vary': 'origin',
    },
    'access-control-allow-methods': 'GET, POST',
    'access-control-allow-headers': ?asked,
    'access-control-expose-headers': 'x-fespalier-probe',
    'access-control-max-age': '0',
  };
}

Future<void> _handle(HttpRequest request, Directory root, bool isPage) async {
  final path = request.uri.path;
  final response = request.response;
  final star = path == '/cors-star';
  _cors(request, star: star).forEach(response.headers.set);
  response.headers.set('cache-control', 'no-store');
  try {
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    switch (path) {
      case '/sse':
        return await _sse(request);
      case '/ws':
        return await _ws(request);
      case '/slow':
        return await _slow(request);
      case '/quiet':
        return await _quiet(request);
      case '/status':
        final code =
            int.tryParse(request.uri.queryParameters['code'] ?? '') ?? 200;
        response
          ..statusCode = code
          ..reasonPhrase = 'Probe'
          ..headers.set('x-fespalier-probe', 'status')
          ..headers.contentType = ContentType.text
          ..write('status $code');
        return await response.close();
      case '/echo':
        final body = await request.fold<List<int>>(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );
        response
          ..headers.set('x-fespalier-probe', 'echo')
          ..headers.contentType = ContentType.binary
          ..add(body);
        return await response.close();
      case '/cors-star':
        response
          ..headers.contentType = ContentType.text
          ..write('ok');
        return await response.close();
      case '/log':
        final id = request.uri.queryParameters['id'];
        response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode([
              for (final line in _log)
                if (id == null || line.split(' ')[1] == id) line,
            ]),
          );
        return await response.close();
    }
    if (isPage) return await _file(request, root);
    response.statusCode = HttpStatus.notFound;
    await response.close();
  } on Object catch (error) {
    stderr.writeln('stream_server: $path: $error');
  }
}

/// The loader pages of the two builds, then the files of [root].
Future<void> _file(HttpRequest request, Directory root) async {
  final response = request.response;
  final path = request.uri.path;
  final loader = switch (path) {
    '/js/' || '/js/index.html' => _jsPage,
    '/wasm/' || '/wasm/index.html' => _wasmPage,
    _ => null,
  };
  if (loader != null) {
    response
      ..headers.contentType = ContentType.html
      ..write(loader);
    return response.close();
  }
  final file = File('${root.path}$path');
  if (path.contains('..') || !file.existsSync()) {
    response.statusCode = HttpStatus.notFound;
    return response.close();
  }
  response.headers.set('content-type', switch (path.split('.').last) {
    'js' || 'mjs' => 'text/javascript',
    'wasm' => 'application/wasm',
    'map' => 'application/json',
    _ => 'application/octet-stream',
  });
  await response.addStream(file.openRead());
  await response.close();
}

const _jsPage = '''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>fetch adapter, dart2js</title></head>
<body><script src="harness.dart.js"></script></body></html>
''';

const _wasmPage = '''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>fetch adapter, dart2wasm</title></head>
<body><script type="module">
import { compileStreaming } from './harness.mjs';
try {
  const app = await compileStreaming(fetch('harness.wasm'));
  const instance = await app.instantiate({});
  instance.invokeMain();
} catch (e) {
  window.fetchResult = JSON.stringify({ error: 'wasm load: ' + e });
  window.fetchDone = true;
}
</script></body></html>
''';

/// The status line and headers of a response written on the raw socket.
String _head(HttpRequest request, Map<String, String> headers) {
  final lines = <String>[
    'HTTP/1.1 200 OK',
    for (final MapEntry(:key, :value) in {
      ..._cors(request),
      ...headers,
    }.entries)
      '$key: $value',
    'cache-control: no-cache',
    'connection: close',
    '',
    '',
  ];
  return lines.join('\r\n');
}

/// Watches [socket] for the client going away; [onGone] runs once.
void _watch(Socket socket, void Function() onGone) {
  var gone = false;
  socket.listen(
    (_) {},
    onDone: () {
      if (!gone) {
        gone = true;
        onGone();
      }
    },
    onError: (Object _) {},
    cancelOnError: false,
  );
}

Future<void> _sse(HttpRequest request) async {
  final id = request.uri.queryParameters['id'] ?? '-';
  // dart:io's HttpResponse does not tell when the client goes away: the raw socket does.
  final socket = await request.response.detachSocket(writeHeaders: false);
  var closed = false;
  var sent = 0;
  _watch(socket, () {
    if (closed) return;
    closed = true;
    _record('closed $id after $sent');
  });
  try {
    socket.write(
      _head(request, {
        'content-type': 'text/event-stream',
        'x-fespalier-probe': 'sse',
      }),
    );
    socket.write('retry: 60000\n: hello\n\n');
    await socket.flush();
    for (var i = 1; i <= 10 && !closed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (closed) break;
      final t = DateTime.now().millisecondsSinceEpoch;
      socket.write('id: $i\ndata: ${jsonEncode({'i': i, 't': t})}\n\n');
      await socket.flush();
      sent = i;
    }
    if (!closed) {
      closed = true;
      _record('ended $id after $sent');
      await socket.close();
    }
  } on Object catch (error) {
    if (!closed) {
      closed = true;
      _record('closed $id after $sent (${error.runtimeType})');
    }
  }
}

Future<void> _quiet(HttpRequest request) async {
  final id = request.uri.queryParameters['id'] ?? '-';
  final socket = await request.response.detachSocket(writeHeaders: false);
  var closed = false;
  var sent = 0;
  _watch(socket, () {
    if (closed) return;
    closed = true;
    _record('closed $id after $sent');
  });
  try {
    socket.write(_head(request, {'content-type': 'text/event-stream'}));
    socket.write(': hello\n\n');
    await socket.flush();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (closed) return;
    socket.write('id: 1\ndata: late\n\n');
    await socket.flush();
    sent = 1;
    closed = true;
    _record('ended $id after 1');
    await socket.close();
  } on Object catch (error) {
    if (!closed) {
      closed = true;
      _record('closed $id after $sent (${error.runtimeType})');
    }
  }
}

Future<void> _slow(HttpRequest request) async {
  final id = request.uri.queryParameters['id'] ?? '-';
  final socket = await request.response.detachSocket(writeHeaders: false);
  var closed = false;
  _watch(socket, () {
    if (closed) return;
    closed = true;
    _record('closed $id before headers');
  });
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  if (closed) return;
  closed = true;
  _record('ended $id after headers');
  try {
    socket.write(_head(request, {'content-type': 'text/plain'}));
    socket.write('slow');
    await socket.close();
  } on Object catch (_) {
    // The client went away as the answer was written.
  }
}

Future<void> _ws(HttpRequest request) async {
  final id = request.uri.queryParameters['id'] ?? '-';
  final ticket = request.uri.queryParameters['ticket'];
  final socket = await WebSocketTransformer.upgrade(
    request,
    protocolSelector: (offered) => offered.contains('fsp.v1') ? 'fsp.v1' : null,
  );
  _record('ws-open $id ticket=$ticket protocol=${socket.protocol}');
  socket
    ..add('hello')
    ..add(<int>[1, 2, 3]);
  try {
    await for (final message in socket) {
      if (message is String && message.startsWith('echo:')) {
        socket.add(message.substring('echo:'.length));
      } else if (message == 'close') {
        await socket.close(4001, 'a reason the client never keeps');
      } else if (message is List<int>) {
        socket.add(message);
      }
    }
  } on Object catch (error) {
    _record('ws-error $id ${error.runtimeType}');
  }
  _record('ws-closed $id code ${socket.closeCode}');
}
