// The live example's server, for a test on a real network (a phone, a browser, Safari):
//
//   dart run tool/server.dart [--host 0.0.0.0] [--port 8080] [--refuse-tickets] [--web build/web]
//
// It answers what the in-process demo server (lib/demo/live_server.dart) answers, over real HTTP and a
// real WebSocket, and logs every connection: `sse-open`, `sse-closed`, `ticket`, `ticket-refused`,
// `ws-open ... ticket=...`, `ws-closed ... code=...`, `ask-open`, `ask-closed` (the client left) and
// `ask-ended`. It listens on every interface by default and prints the addresses a phone on the same
// network can use. dart:io only (and lib/demo/script.dart, pure Dart): no package, no Flutter.
//
// Type a command and Enter while it runs:
//
//   refuse        refuse tickets from now on (POST /ws-ticket answers 401) and close every chat with 4401
//   accept        accept tickets again
//   advance <id>  the next status of order <id>      post <thread>  a new message in a thread (t1, t2, t3)
//   other         a chat message from another phone  kick           close every chat socket (1001)
//   drop          break every event stream           help           this list
//
// The app's buttons do the same through `POST /orders/<id>/advance`, `/orders/<id>/drop`,
// `/inbox/<id>/post`, `/inbox/drop`, `/chat/other`, `/chat/kick` and `/admin/refuse-tickets?on=true|false`.
//
// Every answer carries `access-control-allow-origin: *`, so a web build served from elsewhere (`flutter run
// -d chrome`) can call it. `--web <dir>` also serves a web build from this origin (with the headers a wasm
// build needs), for a phone's browser.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:live/demo/script.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at < 0 || at + 1 >= args.length ? null : args[at + 1];
  }

  final web = option('--web');
  final server = await LiveToolServer.start(
    host: option('--host') ?? '0.0.0.0',
    port: int.parse(option('--port') ?? '8080'),
    web: web == null ? null : Directory(web),
    refuseTickets: args.contains('--refuse-tickets'),
    log: (line) => stdout.writeln('${DateTime.now().toIso8601String()} $line'),
  );
  final port = server.port;
  stdout.writeln('live server on port $port. LIVE_ORIGIN for the app, from:');
  stdout.writeln('  this computer (desktop, Chrome): http://localhost:$port');
  stdout.writeln('  the Android emulator:            http://10.0.2.2:$port');
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final address in interface.addresses) {
      if (address.isLoopback) continue;
      stdout.writeln(
        '  a phone on this network (${interface.name}): http://${address.address}:$port',
      );
    }
  }
  if (web != null) {
    stdout.writeln('The web build in $web is served at the same addresses.');
  }
  stdout.writeln(_help);
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(server.command);
}

const _help =
    'Commands: refuse, accept, advance <id>, post <thread>, other, kick, drop, help. Ctrl+C stops.';

/// The server, started by [start]: what `main` runs, and what test/server_test.dart starts on a free
/// port.
final class LiveToolServer {
  LiveToolServer._(this._http, this._web, this._log, this._refuseTickets) {
    for (final order in scriptOrders) {
      _orders[order.id] = _Order(order);
    }
    for (final thread in scriptThreads) {
      _threads[thread.id] = _Thread(thread);
    }
  }

  /// Listens on [host]:[port] (0 picks a free port) and serves until [close].
  static Future<LiveToolServer> start({
    String host = '0.0.0.0',
    int port = 8080,
    Directory? web,
    bool refuseTickets = false,
    void Function(String line)? log,
  }) async {
    final http = await HttpServer.bind(host, port);
    final server = LiveToolServer._(http, web, log ?? (_) {}, refuseTickets);
    unawaited(http.forEach((request) => unawaited(server._handle(request))));
    return server;
  }

  final HttpServer _http;
  final Directory? _web;
  final void Function(String line) _log;
  bool _refuseTickets;
  final Map<int, _Order> _orders = {};
  final Map<String, _Thread> _threads = {};
  final Set<_EventLine> _inboxLines = {};
  final Map<String, DateTime> _tickets = {};
  final Set<_Chatter> _chatters = {};
  var _connections = 0;
  var _ticketCount = 0;
  var _socketCount = 0;
  var _otherCount = 0;

  /// The port it listens on.
  int get port => _http.port;

  /// Runs one command typed in the terminal.
  void command(String line) {
    final words = line.trim().split(RegExp(r'\s+'));
    switch (words) {
      case ['refuse']:
        _setRefusal(true);
      case ['accept']:
        _setRefusal(false);
      case ['advance', final id]:
        _orders[int.tryParse(id)]?.advance();
      case ['post', final id]:
        _post(id);
      case ['other']:
        _other();
      case ['kick']:
        _kick(1001);
      case ['drop']:
        for (final order in _orders.values) {
          order.lines.toList().forEach((line) => line.drop());
        }
        _inboxLines.toList().forEach((line) => line.drop());
      case [''] || ['help']:
        _log(_help);
      default:
        _log('unknown command: ${line.trim()}. $_help');
    }
  }

  /// Stops listening, and closes every stream and socket.
  Future<void> close() async {
    for (final order in _orders.values) {
      order.lines.toList().forEach((line) => line.drop());
    }
    _inboxLines.toList().forEach((line) => line.drop());
    for (final chatter in _chatters.toList()) {
      await chatter.close(1001);
    }
    await _http.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    _cors(request).forEach(response.headers.set);
    try {
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        return await response.close();
      }
      // A browser that opens or reloads a page of the app (`/inbox`, `/chat`) asks for HTML: that is the
      // web build's, not the API's.
      final web = _web;
      if (web != null &&
          request.method == 'GET' &&
          (request.headers.value('accept') ?? '').contains('text/html')) {
        return await _file(request, web);
      }
      switch ((request.method, segments)) {
        case ('GET', ['orders', final id, 'events']):
          final order = _orders[int.tryParse(id)];
          if (order == null) return await _status(response, 404);
          return await _orderEvents(order, request);
        case ('POST', ['orders', final id, 'advance']):
          final order = _orders[int.tryParse(id)];
          if (order == null) return await _status(response, 404);
          order.advance();
          return await _status(response, 204);
        case ('POST', ['orders', final id, 'drop']):
          final order = _orders[int.tryParse(id)];
          if (order == null) return await _status(response, 404);
          order.lines.toList().forEach((line) => line.drop());
          return await _status(response, 204);
        case ('GET', ['inbox']):
          return await _json(response, [
            for (final thread in _threads.values)
              {'id': thread.script.id, 'title': thread.script.title},
          ]);
        case ('GET', ['inbox', 'changes']):
          return await _inboxEvents(request);
        case ('POST', ['inbox', 'drop']):
          _inboxLines.toList().forEach((line) => line.drop());
          return await _status(response, 204);
        case ('GET', ['inbox', final id]):
          final thread = _threads[id];
          if (thread == null) return await _status(response, 404);
          thread.reads++;
          return await _json(response, thread.toJson());
        case ('POST', ['inbox', final id, 'post']):
          if (!_post(id)) return await _status(response, 404);
          return await _status(response, 204);
        case ('POST', ['ask']):
          return await _ask(request);
        case ('POST', ['ws-ticket']):
          if (_refuseTickets) {
            _log('ticket-refused');
            return await _status(response, 401);
          }
          final ticket = 'tk-${++_ticketCount}';
          _tickets[ticket] = DateTime.now().add(ticketLifetime);
          _log('ticket $ticket');
          return await _json(response, {'ticket': ticket});
        case ('GET', ['chat']):
          return await _chat(request);
        case ('POST', ['chat', 'other']):
          _other();
          return await _status(response, 204);
        case ('POST', ['chat', 'kick']):
          _kick(1001);
          return await _status(response, 204);
        case ('POST', ['admin', 'refuse-tickets']):
          _setRefusal(request.uri.queryParameters['on'] != 'false');
          return await _status(response, 204);
      }
      if (request.method == 'GET' && _web != null) {
        return await _file(request, _web);
      }
      await _status(response, 404);
    } on Object catch (error) {
      _log('error ${request.method} ${request.uri.path}: ${error.runtimeType}');
    }
  }

  void _setRefusal(bool on) {
    _refuseTickets = on;
    _log('refuse-tickets ${on ? 'on' : 'off'}');
    if (on) _kick(sessionEndedCode);
  }

  void _kick(int code) {
    for (final chatter in _chatters.toList()) {
      unawaited(chatter.close(code));
    }
  }

  bool _post(String id) {
    final thread = _threads[id];
    if (thread == null) return false;
    thread.messages++;
    for (final line in _inboxLines.toList()) {
      line.write('data: ${jsonEncode({'thread': id})}\n\n');
    }
    return true;
  }

  void _other() {
    _otherCount++;
    for (final chatter in _chatters.toList()) {
      chatter.send({
        'type': 'message',
        'from': 'other phone',
        'text': 'Hello from the other phone ($_otherCount)',
      });
    }
  }

  Future<void> _orderEvents(_Order order, HttpRequest request) async {
    final resumeFrom = int.tryParse(
      request.headers.value('last-event-id') ?? '',
    );
    final line = await _openEvents(
      request,
      'order-${order.script.id}',
      order.lines.remove,
      resumed: resumeFrom,
    );
    order.lines.add(line);
    // What the client missed since the event it resumes from, or the order now; a client that is up to
    // date gets the last event again, so a page watched again has a value.
    final missed = [
      for (var seq = (resumeFrom ?? 0) + 1; seq <= order.seq; seq++) seq,
    ];
    for (final seq in missed.isEmpty ? [order.seq] : missed) {
      line.write(order.event(seq));
    }
  }

  Future<void> _inboxEvents(HttpRequest request) async {
    final line = await _openEvents(request, 'inbox', _inboxLines.remove);
    _inboxLines.add(line);
    line.write(': hello\n\n');
  }

  Future<_EventLine> _openEvents(
    HttpRequest request,
    String label,
    void Function(_EventLine line) onGone, {
    int? resumed,
  }) async {
    final number = ++_connections;
    _log(
      'sse-open #$number $label${resumed == null ? '' : ' last-event-id=$resumed'}',
    );
    // dart:io's HttpResponse does not say when the client goes away: the raw socket does.
    final socket = await request.response.detachSocket(writeHeaders: false);
    socket.write(
      _head(request, {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        // Asks a proxy (nginx) not to buffer the stream.
        'x-accel-buffering': 'no',
      }),
    );
    return _EventLine(number, label, socket, _log, onGone);
  }

  Future<void> _ask(HttpRequest request) async {
    final question = await utf8.decoder.bind(request).join();
    final words = answerWords(question);
    final number = ++_connections;
    _log('ask-open #$number');
    final socket = await request.response.detachSocket(writeHeaders: false);
    var open = true;
    var sent = 0;
    _watch(socket, () {
      if (!open) return;
      open = false;
      _log('ask-closed #$number after $sent words (the client left)');
    });
    try {
      socket.write(
        _head(request, {'content-type': 'text/plain; charset=utf-8'}),
      );
      await socket.flush();
      for (final word in words) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!open) return;
        socket.add(_chunk(sent == 0 ? word : ' $word'));
        await socket.flush();
        sent++;
      }
      if (open) {
        open = false;
        _log('ask-ended #$number after $sent words');
        socket.write(_lastChunk);
        await socket.close();
      }
    } on Object catch (_) {
      if (open) {
        open = false;
        _log('ask-closed #$number after $sent words (the client left)');
      }
    }
  }

  Future<void> _chat(HttpRequest request) async {
    final ticket = request.uri.queryParameters['ticket'];
    // Single-use: a ticket is gone once it was shown, accepted or not.
    final expires = _tickets.remove(ticket);
    if (expires == null ||
        DateTime.now().isAfter(expires) ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      _log('ws-refused ticket=$ticket');
      return _status(request.response, 401);
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final chatter = _Chatter(++_socketCount, socket);
    _chatters.add(chatter);
    _log('ws-open #${chatter.number} ticket=$ticket');
    // Something to hear while there is nothing to say, so the app's LiveRules.idle tells a dead socket
    // (a NAT that forgot it, a radio asleep) from a quiet one. The app's decoder skips it.
    final ping = Timer.periodic(
      const Duration(seconds: 20),
      (_) => chatter.send({'type': 'ping'}),
    );
    try {
      await for (final message in socket) {
        if (message is! String) continue;
        final json = jsonDecode(message);
        switch (json) {
          case {'join': final String room}:
            chatter.send({'type': 'joined', 'room': room, 'as': chatter.name});
          case {'say': final String said}:
            for (final other in _chatters.toList()) {
              other.send({
                'type': 'message',
                'from': identical(other, chatter) ? 'you' : chatter.name,
                'text': said,
              });
            }
        }
      }
    } on Object catch (error) {
      _log('ws-error #${chatter.number} ${error.runtimeType}');
    } finally {
      ping.cancel();
      _chatters.remove(chatter);
      _log(
        'ws-closed #${chatter.number} code=${socket.closeCode}'
        '${chatter.closedByServer ? ' (server)' : ' (client)'}',
      );
    }
  }

  /// A file of the web build, `index.html` for a path that names none, with the headers a wasm build
  /// needs (cross-origin isolation).
  Future<void> _file(HttpRequest request, Directory web) async {
    final response = request.response;
    final path = request.uri.path;
    var file = File('${web.path}$path');
    if (path.contains('..')) return _status(response, 404);
    if (path.endsWith('/') || !file.existsSync()) {
      file = File('${web.path}/index.html');
    }
    if (!file.existsSync()) return _status(response, 404);
    response.headers
      ..set('content-type', switch (file.path.split('.').last) {
        'html' => 'text/html; charset=utf-8',
        'js' || 'mjs' => 'text/javascript',
        'wasm' => 'application/wasm',
        'json' => 'application/json',
        'css' => 'text/css',
        'png' => 'image/png',
        'ttf' => 'font/ttf',
        'otf' => 'font/otf',
        _ => 'application/octet-stream',
      })
      ..set('cross-origin-opener-policy', 'same-origin')
      ..set('cross-origin-embedder-policy', 'require-corp')
      ..set('cache-control', 'no-store');
    await response.addStream(file.openRead());
    await response.close();
  }
}

Map<String, String> _cors(HttpRequest request) => {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers':
      request.headers.value('access-control-request-headers') ?? '*',
  'access-control-max-age': '600',
  // A web build served from this origin with cross-origin isolation may still read the answers.
  'cross-origin-resource-policy': 'cross-origin',
};

Future<void> _status(HttpResponse response, int code) {
  response.statusCode = code;
  return response.close();
}

Future<void> _json(HttpResponse response, Object value) {
  response
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  return response.close();
}

/// The status line and headers of a response written on the raw socket, its body in chunks: a
/// connection that breaks before the last chunk is a body that broke, never an orderly end, which is
/// how "drop" looks like a network that went away.
String _head(HttpRequest request, Map<String, String> headers) => [
  'HTTP/1.1 200 OK',
  for (final MapEntry(:key, :value) in {..._cors(request), ...headers}.entries)
    '$key: $value',
  'transfer-encoding: chunked',
  'connection: close',
  '',
  '',
].join('\r\n');

/// [text] as one chunk of a chunked body.
List<int> _chunk(String text) {
  final bytes = utf8.encode(text);
  return [
    ...ascii.encode('${bytes.length.toRadixString(16)}\r\n'),
    ...bytes,
    13,
    10,
  ];
}

/// The end of a chunked body.
const _lastChunk = '0\r\n\r\n';

/// Watches [socket] for the client going away; [onGone] runs once.
void _watch(Socket socket, void Function() onGone) {
  var gone = false;
  socket.listen(
    (_) {},
    onDone: () {
      if (gone) return;
      gone = true;
      onGone();
    },
    onError: (Object _) {},
    cancelOnError: false,
  );
}

final class _Order {
  _Order(this.script);

  final ScriptOrder script;
  final Set<_EventLine> lines = {};
  final List<String> history = [orderStatuses.first];

  int get seq => history.length;

  void advance() {
    final next = orderStatuses.indexOf(history.last) + 1;
    if (next >= orderStatuses.length) return;
    history.add(orderStatuses[next]);
    for (final line in lines.toList()) {
      line.write(event(seq));
    }
  }

  String event(int seq) =>
      'id: $seq\ndata: ${jsonEncode({'id': script.id, 'item': script.item, 'status': history[seq - 1], 'seq': seq})}\n\n';
}

final class _Thread {
  _Thread(this.script) : messages = script.messages;

  final ScriptThread script;
  int messages;
  int reads = 0;

  Map<String, Object?> toJson() => {
    'id': script.id,
    'title': script.title,
    'messages': messages,
    'reads': reads,
  };
}

/// One event stream, written on the raw socket, with a comment every 15 s while it is quiet.
final class _EventLine {
  _EventLine(this.number, this.label, this._socket, this._log, this._onGone) {
    _watch(_socket, () => _gone('the client left'));
    _ping = Timer.periodic(
      const Duration(seconds: 15),
      (_) => write(': ping\n\n'),
    );
  }

  final int number;
  final String label;
  final Socket _socket;
  final void Function(String line) _log;
  final void Function(_EventLine line) _onGone;
  late final Timer _ping;
  var _open = true;

  void write(String text) {
    if (!_open) return;
    try {
      _socket.add(_chunk(text));
    } on Object catch (_) {
      _gone('the client left');
    }
  }

  void _gone(String why) {
    if (!_open) return;
    _open = false;
    _ping.cancel();
    _onGone(this);
    _log('sse-closed #$number $label ($why)');
  }

  /// Breaks the connection, as a network that drops does: no orderly end.
  void drop() {
    if (!_open) return;
    _gone('dropped');
    _socket.destroy();
  }
}

final class _Chatter {
  _Chatter(this.number, this._socket);

  final int number;
  final WebSocket _socket;
  var closedByServer = false;

  String get name => 'guest-$number';

  void send(Map<String, Object?> message) {
    if (_socket.readyState == WebSocket.open) _socket.add(jsonEncode(message));
  }

  Future<void> close(int code) {
    closedByServer = true;
    return _socket.close(code);
  }
}
