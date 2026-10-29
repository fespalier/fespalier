import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_stream/web_socket.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:live/demo/script.dart';

/// The in-process server the app talks to unless `--dart-define=LIVE_ORIGIN=...` names a real one (no
/// network, no backend: `flutter run` and the web build need nothing else). It answers the routes
/// tool/server.dart answers, through the two seams a real server is reached by: an [HttpTransport] for the
/// requests and the event streams, and a [SocketConnector] for the chat's WebSocket.
///
/// | Request                          | Answer                                                                        |
/// | -------------------------------- | ----------------------------------------------------------------------------- |
/// | `GET /orders/<id>/events`        | an event stream: the order now (`id:` its event number), then each change     |
/// | `POST /orders/<id>/advance`      | the order's next status, to every stream of it                                |
/// | `POST /orders/<id>/drop`         | breaks that order's streams, as a network drop does                          |
/// | `GET /inbox`, `GET /inbox/<id>`  | the threads, and one thread with how many times it was read                   |
/// | `GET /inbox/changes`             | an event stream of `{"thread": "<id>"}`, with no `id:`: every reopen is a gap |
/// | `POST /inbox/<id>/post`          | a new message in that thread, and its change event                            |
/// | `POST /inbox/drop`               | breaks the inbox's streams                                                    |
/// | `POST /ask`                      | the answer to the body's question, one word per chunk                         |
/// | `POST /ws-ticket`                | `{"ticket": "tk-<n>"}`, single-use, or 401 while it refuses tickets           |
/// | WebSocket `/chat?ticket=<t>`     | the chat: `{"join": ...}` and `{"say": ...}` in, `joined` and `message` out   |
/// | `POST /chat/other`               | a message from another phone                                                  |
/// | `POST /chat/kick`                | closes every chat socket (1001), as a server going away does                  |
/// | `POST /admin/refuse-tickets?on=` | refuses tickets from now on (and closes the chat with 4401), or accepts again |
///
/// It emits only when a button asks it to, or a bounded number of words for `/ask`, so every screen
/// settles. [log] keeps what tool/server.dart prints, in the same words.
final class LiveServer implements HttpTransport, SocketConnector {
  /// A server whose answers to `/ask` come [wordPace] apart.
  LiveServer({this.wordPace = const Duration(milliseconds: 120)}) {
    for (final order in scriptOrders) {
      _orders[order.id] = _Order(order);
    }
    for (final thread in scriptThreads) {
      _threads[thread.id] = _Thread(thread);
    }
  }

  /// How far apart the words of an answer are.
  final Duration wordPace;

  final Map<int, _Order> _orders = {};
  final Map<String, _Thread> _threads = {};
  final Set<_EventLine> _inboxLines = {};
  final Map<String, DateTime> _tickets = {};
  final Set<_DemoSocket> _sockets = {};
  final List<String> _log = [];
  var _connections = 0;
  var _ticketCount = 0;
  var _socketCount = 0;
  var _otherCount = 0;
  var _refuseTickets = false;

  /// What the server did, oldest first: `sse-open`, `sse-closed`, `ticket`, `ws-open`, `ws-closed`, ...
  List<String> get log => List.unmodifiable(_log);

  /// Whether `POST /ws-ticket` is answered 401.
  bool get refusesTickets => _refuseTickets;

  /// The chat sockets open now.
  int get openSockets => _sockets.length;

  void _record(String line) => _log.add(line);

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final query = request.uri.queryParameters;
    switch ((request.method, request.uri.pathSegments)) {
      case ('GET', ['orders', final id, 'events']):
        final order = _orders[int.tryParse(id)];
        if (order == null) return _status(404);
        return _orderEvents(order, request);
      case ('POST', ['orders', final id, 'advance']):
        final order = _orders[int.tryParse(id)];
        if (order == null) return _status(404);
        order.advance();
        return _status(204);
      case ('POST', ['orders', final id, 'drop']):
        final order = _orders[int.tryParse(id)];
        if (order == null) return _status(404);
        for (final line in order.lines.toList()) {
          line.drop();
        }
        return _status(204);
      case ('GET', ['inbox']):
        return _json([
          for (final thread in _threads.values)
            {'id': thread.script.id, 'title': thread.script.title},
        ]);
      case ('GET', ['inbox', 'changes']):
        return _inboxEvents(request);
      case ('POST', ['inbox', 'drop']):
        for (final line in _inboxLines.toList()) {
          line.drop();
        }
        return _status(204);
      case ('GET', ['inbox', final id]):
        final thread = _threads[id];
        if (thread == null) return _status(404);
        thread.reads++;
        return _json(thread.toJson());
      case ('POST', ['inbox', final id, 'post']):
        final thread = _threads[id];
        if (thread == null) return _status(404);
        thread.messages++;
        for (final line in _inboxLines.toList()) {
          line.write('data: ${jsonEncode({'thread': id})}\n\n');
        }
        return _status(204);
      case ('POST', ['ask']):
        return _ask(request);
      case ('POST', ['ws-ticket']):
        if (_refuseTickets) {
          _record('ticket-refused');
          return _status(401);
        }
        final ticket = 'tk-${++_ticketCount}';
        _tickets[ticket] = DateTime.now().add(ticketLifetime);
        _record('ticket $ticket');
        return _json({'ticket': ticket});
      case ('POST', ['chat', 'other']):
        _otherCount++;
        _broadcast(
          null,
          'other phone',
          'Hello from the other phone ($_otherCount)',
        );
        return _status(204);
      case ('POST', ['chat', 'kick']):
        for (final socket in _sockets.toList()) {
          socket.closeFromServer(1001);
        }
        return _status(204);
      case ('POST', ['admin', 'refuse-tickets']):
        _refuseTickets = query['on'] != 'false';
        _record('refuse-tickets ${_refuseTickets ? 'on' : 'off'}');
        if (_refuseTickets) {
          for (final socket in _sockets.toList()) {
            socket.closeFromServer(sessionEndedCode);
          }
        }
        return _status(204);
    }
    return _status(404);
  }

  TransportResponse _orderEvents(_Order order, TransportRequest request) {
    final resumeFrom = int.tryParse(_header(request, 'last-event-id') ?? '');
    final line = _open(
      'order-${order.script.id}',
      request,
      onGone: order.lines.remove,
      resumed: resumeFrom,
    );
    order.lines.add(line);
    // What the client missed since the event it resumes from, or the order now. A client that is up to
    // date gets the last event again, so a page that was disposed and is watched again has a value.
    final missed = [
      for (var seq = (resumeFrom ?? 0) + 1; seq <= order.seq; seq++) seq,
    ];
    for (final seq in missed.isEmpty ? [order.seq] : missed) {
      line.write(order.event(seq));
    }
    return line.response;
  }

  TransportResponse _inboxEvents(TransportRequest request) {
    final line = _open('inbox', request, onGone: _inboxLines.remove);
    _inboxLines.add(line);
    line.write(': hello\n\n');
    return line.response;
  }

  _EventLine _open(
    String label,
    TransportRequest request, {
    required void Function(_EventLine line) onGone,
    int? resumed,
  }) {
    final number = ++_connections;
    _record(
      'sse-open #$number $label${resumed == null ? '' : ' last-event-id=$resumed'}',
    );
    final line = _EventLine(number, label, _record, onGone);
    unawaited(request.abortTrigger?.then((_) => line.abort()));
    return line;
  }

  Future<TransportResponse> _ask(TransportRequest request) async {
    final question = utf8.decode(
      request.body ??
          await (request.bodyStream ?? const Stream<List<int>>.empty())
              .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)),
    );
    final words = answerWords(question);
    final number = ++_connections;
    _record('ask-open #$number');
    var sent = 0;
    var open = true;
    late final StreamController<List<int>> body;
    void stop(String how) {
      if (!open) return;
      open = false;
      _record('ask-$how #$number after $sent words');
    }

    body = StreamController<List<int>>(
      onListen: () async {
        for (final word in words) {
          await Future<void>.delayed(wordPace);
          if (!open) return;
          body.add(utf8.encode(sent == 0 ? word : ' $word'));
          sent++;
        }
        stop('ended');
        await body.close();
      },
      onCancel: () => stop('closed'),
    );
    unawaited(
      request.abortTrigger?.then((_) {
        if (!open) return;
        stop('closed');
        body.addError(const DemoAborted());
        unawaited(body.close());
      }),
    );
    return TransportResponse(
      statusCode: 200,
      headers: const {'content-type': 'text/plain; charset=utf-8'},
      body: body.stream,
    );
  }

  @override
  Future<StreamSocket> connect(
    Uri url, {
    Iterable<String> protocols = const <String>[],
    Map<String, String> headers = const <String, String>{},
  }) async {
    final ticket = url.queryParameters['ticket'];
    // Single-use: a ticket is gone once it was shown, accepted or not.
    final expires = _tickets.remove(ticket);
    if (url.path != '/chat' ||
        expires == null ||
        DateTime.now().isAfter(expires)) {
      _record('ws-refused ticket=$ticket');
      throw WebSocketException('the server refused the handshake');
    }
    final socket = _DemoSocket(this, ++_socketCount);
    _sockets.add(socket);
    _record('ws-open #${socket.number} ticket=$ticket');
    return socket;
  }

  void _broadcast(_DemoSocket? from, String name, String text) {
    for (final socket in _sockets.toList()) {
      socket.deliver({
        'type': 'message',
        'from': identical(socket, from) ? 'you' : name,
        'text': text,
      });
    }
  }

  /// Ends every stream and socket: the container that held the server is gone.
  void close() {
    for (final order in _orders.values) {
      for (final line in order.lines.toList()) {
        line.end();
      }
    }
    for (final line in _inboxLines.toList()) {
      line.end();
    }
    for (final socket in _sockets.toList()) {
      socket.closeFromServer(1001);
    }
  }

  @override
  String toString() => 'LiveServer';
}

/// What an aborted request's body ends with, as a real client's does.
final class DemoAborted implements Exception {
  /// The body of an aborted request.
  const DemoAborted();

  @override
  String toString() => 'DemoAborted';
}

/// What a dropped stream's body ends with: the connection was reset.
final class DemoConnectionReset implements Exception {
  /// A dropped connection.
  const DemoConnectionReset();

  @override
  String toString() => 'DemoConnectionReset';
}

String? _header(TransportRequest request, String lower) {
  for (final MapEntry(:key, :value) in request.headers.entries) {
    if (key.toLowerCase() == lower) return value;
  }
  return null;
}

TransportResponse _status(int code) => TransportResponse.fromBytes(
  statusCode: code,
  headers: const {},
  bytes: Uint8List(0),
);

TransportResponse _json(Object value) => TransportResponse.fromBytes(
  statusCode: 200,
  headers: const {'content-type': 'application/json'},
  bytes: utf8.encode(jsonEncode(value)),
);

final class _Order {
  _Order(this.script);

  final ScriptOrder script;
  final Set<_EventLine> lines = {};

  /// The status of each event, the first at index 0 (event 1).
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

/// One event stream the server is writing.
final class _EventLine {
  _EventLine(this.number, this.label, this._record, this._onGone) {
    _body = StreamController<List<int>>(onCancel: () => _gone('client left'));
  }

  final int number;
  final String label;
  final void Function(String line) _record;
  final void Function(_EventLine line) _onGone;
  late final StreamController<List<int>> _body;
  var _open = true;

  TransportResponse get response => TransportResponse(
    statusCode: 200,
    headers: const {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
    },
    body: _body.stream,
  );

  void write(String text) {
    if (_open) _body.add(utf8.encode(text));
  }

  void _gone(String why) {
    if (!_open) return;
    _open = false;
    _onGone(this);
    _record('sse-closed #$number $label ($why)');
  }

  void abort() {
    if (!_open) return;
    _gone('client left');
    _body.addError(const DemoAborted());
    unawaited(_body.close());
  }

  void drop() {
    if (!_open) return;
    _gone('dropped');
    _body.addError(const DemoConnectionReset());
    unawaited(_body.close());
  }

  void end() {
    if (!_open) return;
    _gone('ended');
    unawaited(_body.close());
  }
}

/// One chat socket, the server's end and the client's at once.
final class _DemoSocket implements StreamSocket {
  _DemoSocket(this._server, this.number);

  final LiveServer _server;
  final int number;
  final StreamController<SocketMessage> _messages =
      StreamController<SocketMessage>();
  var _open = true;

  String get _name => 'guest-$number';

  @override
  String get protocol => '';

  @override
  Stream<SocketMessage> get messages => _messages.stream;

  void deliver(Map<String, Object?> message) {
    if (_open) _messages.add(SocketText(jsonEncode(message)));
  }

  @override
  void sendText(String text) {
    if (!_open) throw WebSocketConnectionClosed();
    final message = jsonDecode(text);
    if (message is! Map<String, Object?>) return;
    switch (message) {
      case {'join': final String room}:
        deliver({'type': 'joined', 'room': room, 'as': _name});
      case {'say': final String said}:
        _server._broadcast(this, _name, said);
    }
  }

  @override
  void sendBytes(Uint8List bytes) {
    if (!_open) throw WebSocketConnectionClosed();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    _server._sockets.remove(this);
    _server._record('ws-closed #$number code=${code ?? 1005} (client)');
    await _messages.close();
  }

  void closeFromServer(int code) {
    if (!_open) return;
    _open = false;
    _server._sockets.remove(this);
    _server._record('ws-closed #$number code=$code (server)');
    _messages.addError(SocketClosed(code));
    unawaited(_messages.close());
  }
}
