/// What tests use from fespalier_stream (since 0.25.0): [FakeEventServer], an `HttpTransport` that
/// serves event streams the test writes to; [ManualStreamTicker], a tick fired by hand;
/// [FakeLiveConnection], a connection the test drives; [FakeChangeSource], a change stream the test
/// feeds (fespalier_frb's until 0.24); [FakeSocketConnector], WebSockets the test plays the peer
/// of; and [streamTestOverrides].
///
/// It exports `package:fespalier_stream/fespalier_stream.dart` and
/// `package:fespalier_stream/web_socket.dart`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_transport/fespalier_transport.dart';

import 'fespalier_stream.dart';
import 'web_socket.dart';

export 'package:fespalier_stream/fespalier_stream.dart';
export 'package:fespalier_stream/web_socket.dart';

/// A [StreamTicker] a test fires: `streamTicker.overrideWith(ManualStreamTicker.new)`, then
/// `(container.read(streamTicker.notifier) as ManualStreamTicker).tick()`.
class ManualStreamTicker extends StreamTicker {
  /// One tick: the signal fires and every feed's connection is swept.
  void tick() => fire();
}

/// The overrides a test of live feeds starts from: [streamTicker] with a [ManualStreamTicker].
List<Override> streamTestOverrides() => <Override>[
  streamTicker.overrideWith(ManualStreamTicker.new),
];

/// The error a [FakeEventConnection]'s body ends with when its request is aborted: what a real
/// client puts there (`package:http`'s `RequestAbortedException`, a cancelled `DioException`),
/// never a `TransportFailure`.
final class FakeAbortedBody implements Exception {
  /// The body of an aborted request.
  const FakeAbortedBody();

  @override
  String toString() => 'FakeAbortedBody: the request was aborted';
}

/// One event stream a [FakeEventServer] is serving: the test writes to it.
final class FakeEventConnection {
  FakeEventConnection._(this.request) {
    _body = StreamController<List<int>>(
      onPause: () => pauseCount++,
      onCancel: () => cancelled = true,
    );
  }

  /// The request that opened it.
  final TransportRequest request;

  late final StreamController<List<int>> _body;

  /// Whether the client completed the request's `abortTrigger`.
  bool aborted = false;

  /// Whether the client cancelled its subscription to the body.
  bool cancelled = false;

  /// Whether the server ended the body ([end] or [drop]).
  bool ended = false;

  /// How many times the client paused the body (a `StreamIterator` pauses between two reads, so
  /// only [isPaused] after the reader settled says the client stopped reading).
  int pauseCount = 0;

  /// The request's `Last-Event-ID`, or null.
  String? get lastEventId => _header('last-event-id');

  /// The request's header [name] (any case), or null.
  String? header(String name) => _header(name.toLowerCase());

  String? _header(String lower) {
    for (final MapEntry(:key, :value) in request.headers.entries) {
      if (key.toLowerCase() == lower) return value;
    }
    return null;
  }

  /// Whether the client is not reading now.
  bool get isPaused => _body.isPaused;

  /// Whether the body can still be written to and read: not ended, aborted or cancelled.
  bool get isOpen => !ended && !aborted && !cancelled;

  /// Writes one event: `event:` when [type] is given, `id:` when [id] is, one `data:` line per
  /// line of [data], and the blank line that dispatches it.
  void event(String data, {String? type, String? id}) {
    final out = StringBuffer();
    if (type != null) out.write('event: $type\n');
    if (id != null) out.write('id: $id\n');
    for (final line in const LineSplitter().convert(data)) {
      out.write('data: $line\n');
    }
    if (data.isEmpty) out.write('data:\n');
    out.write('\n');
    write(out.toString());
  }

  /// Writes a comment, what a server sends to say it is alive.
  void comment([String text = 'ping']) => write(': $text\n\n');

  /// Writes a `retry:` field.
  void retry(Duration delay) => write('retry: ${delay.inMilliseconds}\n\n');

  /// Writes [text] as it is, UTF-8.
  void write(String text) => writeBytes(utf8.encode(text));

  /// Writes [bytes] as one chunk.
  void writeBytes(List<int> bytes) {
    if (!isOpen) return;
    _body.add(bytes);
  }

  /// Ends the body in order.
  void end() {
    if (ended) return;
    ended = true;
    unawaited(_body.close());
  }

  /// Breaks the body with [error] (a connection reset, by default), as a network drop does.
  void drop([Object? error]) {
    if (ended) return;
    ended = true;
    _body.addError(error ?? const FakeConnectionReset());
    unawaited(_body.close());
  }

  void _abort() {
    if (aborted) return;
    aborted = true;
    if (ended) return;
    ended = true;
    _body.addError(const FakeAbortedBody());
    unawaited(_body.close());
  }

  @override
  String toString() => 'FakeEventConnection';
}

/// The error [FakeEventConnection.drop] breaks a body with by default.
final class FakeConnectionReset implements Exception {
  /// A dropped connection.
  const FakeConnectionReset();

  @override
  String toString() => 'FakeConnectionReset: the connection was reset';
}

/// An `HttpTransport` that serves event streams, for tests (since 0.25.0).
///
/// Each request is answered with the next scripted answer ([respond], [fail], [hang]) or, when
/// none is left, with a `200 text/event-stream` whose body is a [FakeEventConnection] the test
/// writes to ([current], [connections]). It honours the `abortTrigger` as a real client does: an
/// abort before the answer fails the send with `TransportAborted`, and an abort after it ends the
/// body with [FakeAbortedBody] (not a `TransportFailure`). It starts no timer and listens to
/// nothing: the trigger is followed with a side `then`.
final class FakeEventServer implements HttpTransport {
  /// A server with nothing scripted.
  FakeEventServer();

  final Queue<Object> _script = Queue<Object>();
  final List<TransportRequest> _requests = <TransportRequest>[];
  final List<FakeEventConnection> _connections = <FakeEventConnection>[];
  int _aborts = 0;

  /// The requests sent so far, oldest first.
  List<TransportRequest> get requests =>
      List<TransportRequest>.unmodifiable(_requests);

  /// The event streams served so far, oldest first.
  List<FakeEventConnection> get connections =>
      List<FakeEventConnection>.unmodifiable(_connections);

  /// The last event stream served.
  FakeEventConnection get current => _connections.last;

  /// How many requests had their `abortTrigger` completed, before or after their answer.
  int get abortCount => _aborts;

  /// The next request is answered with [status], [headers] and a text [body].
  void respond(
    int status, {
    Map<String, String> headers = const <String, String>{},
    String body = '',
  }) => _script.add(
    TransportResponse(
      statusCode: status,
      headers: <String, String>{
        for (final MapEntry(:key, :value) in headers.entries)
          key.toLowerCase(): value,
      },
      body: Stream<List<int>>.value(utf8.encode(body)),
    ),
  );

  /// The next request fails with [error] (a `TransportFailure`, or a decorator's own error).
  void fail(Object error) => _script.add(_Fail(error));

  /// The next request gets no answer until its `abortTrigger` completes.
  void hang() => _script.add(const _Hang());

  @override
  Future<TransportResponse> send(TransportRequest request) {
    _requests.add(request);
    final trigger = request.abortTrigger;
    final answer = _script.isEmpty ? null : _script.removeFirst();
    var aborted = false;
    unawaited(
      trigger?.then<void>((_) {
        if (aborted) return;
        aborted = true;
        _aborts++;
      }),
    );
    switch (answer) {
      case _Fail(:final error):
        return Future<TransportResponse>.error(error);
      case _Hang():
        final pending = Completer<TransportResponse>();
        unawaited(
          trigger?.then<void>((_) {
            if (!pending.isCompleted) {
              pending.completeError(TransportAborted(null, request.uri));
            }
          }),
        );
        return pending.future;
      case final TransportResponse response:
        return Future<TransportResponse>.value(response);
    }
    final connection = FakeEventConnection._(request);
    _connections.add(connection);
    unawaited(trigger?.then<void>((_) => connection._abort()));
    return Future<TransportResponse>.value(
      TransportResponse(
        statusCode: 200,
        headers: const <String, String>{
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
        },
        body: connection._body.stream,
      ),
    );
  }

  @override
  String toString() => 'FakeEventServer';
}

final class _Fail {
  const _Fail(this.error);

  final Object error;
}

final class _Hang {
  const _Hang();
}

/// A [LiveConnection] a test drives (since 0.25.0): it delivers what the test [emit]s and shows
/// the status the test sets, and counts what a feed asked of it.
final class FakeLiveConnection<T> implements LiveConnection<T> {
  /// A connection showing [status], resuming from [lastEventId].
  FakeLiveConnection({
    LiveStatus status = const LiveConnecting(1),
    this.lastEventId,
  }) : _status = status {
    _events = StreamController<T>(
      onListen: () => listenCount++,
      onCancel: () => cancelled = true,
    );
  }

  late final StreamController<T> _events;
  LiveStatus _status;
  final Set<MultiStreamController<LiveStatus>> _watchers =
      <MultiStreamController<LiveStatus>>{};

  @override
  String? lastEventId;

  @override
  DateTime? lastSeen;

  /// How many times [events] was listened to (at most once: it is single-subscription).
  int listenCount = 0;

  /// Whether the listener cancelled.
  bool cancelled = false;

  /// Whether [close] was called.
  bool closed = false;

  /// How many times [reconnect] was called.
  int reconnectCount = 0;

  /// The limits [closeIfIdle] was called with.
  final List<Duration> idleChecks = <Duration>[];

  /// How many times [closeIfPaused] was called.
  int pauseChecks = 0;

  /// Whether the listener paused the events now.
  bool get isPaused => _events.isPaused;

  /// Delivers [event].
  void emit(T event) => _events.add(event);

  /// Delivers an error.
  void emitError(Object error) => _events.addError(error);

  /// Shows [status] (and ends [events] for a [LiveDone]).
  void setStatus(LiveStatus status) {
    if (status == _status) return;
    _status = status;
    for (final watcher in _watchers.toList()) {
      watcher.add(status);
      if (status is LiveDone) unawaited(watcher.close());
    }
    if (status is LiveDone) {
      _watchers.clear();
      unawaited(_events.close());
    }
  }

  @override
  Stream<T> get events => _events.stream;

  @override
  LiveStatus get status => _status;

  @override
  Stream<LiveStatus> get statusChanges =>
      Stream<LiveStatus>.multi((controller) {
        controller.add(_status);
        if (_status is LiveDone) {
          controller.close();
          return;
        }
        _watchers.add(controller);
        controller.onCancel = () => _watchers.remove(controller);
      }, isBroadcast: true);

  /// Counts the call; a waiting connection becomes [LiveConnecting] and answers true.
  @override
  bool reconnect() {
    reconnectCount++;
    if (_status is! LiveWaiting) return false;
    setStatus(const LiveConnecting(1));
    return true;
  }

  /// Counts the call and answers false.
  @override
  bool closeIfIdle(Duration limit) {
    idleChecks.add(limit);
    return false;
  }

  /// Counts the call and answers false.
  @override
  bool closeIfPaused() {
    pauseChecks++;
    return false;
  }

  @override
  Future<void> close() async {
    closed = true;
    setStatus(const LiveDone(LiveEnd.closed));
  }

  @override
  String toString() => 'FakeLiveConnection';
}

/// A fake change stream, a Rust core's for instance (since 0.13.0, in fespalier_stream since
/// 0.25.0): fed by the test, counting its listeners.
///
/// `ChangeFeed((ref) => fake.stream)` is the feed under test. Events are delivered **synchronously**
/// to the one subscription (a broadcast controller, or a single-subscription one with
/// `broadcast: false`, like flutter_rust_bridge's streams, which refuse a second listener).
///
/// Since 0.18.0 it is also the raw source of a codec (an `EventCodec`, or fespalier_frb's
/// `ChangeCodec`): `FakeChangeSource<String>`, or `<Uint8List>`.
final class FakeChangeSource<E> {
  /// Creates a source. [broadcast] false makes it single-subscription, like a generated stream.
  FakeChangeSource({bool broadcast = true}) {
    void listened() => listenCount++;
    void cancelled() => cancelCount++;
    _controller = broadcast
        ? StreamController<E>.broadcast(
            sync: true,
            onListen: listened,
            onCancel: cancelled,
          )
        : StreamController<E>(
            sync: true,
            onListen: listened,
            onCancel: cancelled,
          );
  }

  late final StreamController<E> _controller;

  /// How many times the stream was listened to: 1 for any number of topics.
  int listenCount = 0;

  /// How many times a listener cancelled (a container's disposal does).
  int cancelCount = 0;

  /// The stream a feed opens.
  Stream<E> get stream => _controller.stream;

  /// Whether someone is subscribed now.
  bool get hasListener => _controller.hasListener;

  /// Delivers [event].
  void emit(E event) => _controller.add(event);

  /// Delivers an error.
  void emitError(Object error) => _controller.addError(error);

  /// Ends the stream.
  Future<void> close() => _controller.close();
}

/// A WebSocket a [FakeSocketConnector] opened (since 0.25.0): the test is the peer. It writes
/// with [text] and [bytes], closes with [closeFromPeer] or [drop], and reads what the client
/// [sent].
final class FakeSocket implements StreamSocket {
  FakeSocket._(this.url, this.protocols, this.headers, this.protocol) {
    _messages = StreamController<SocketMessage>(
      onPause: () => pauseCount++,
      onCancel: () => cancelled = true,
    );
  }

  /// The URL it was opened with (a grant's, ticket included).
  final Uri url;

  /// The subprotocols the client offered.
  final List<String> protocols;

  /// The handshake's headers.
  final Map<String, String> headers;

  @override
  final String protocol;

  late final StreamController<SocketMessage> _messages;
  bool _ended = false;

  /// What the client sent, oldest first.
  final List<SocketMessage> sent = <SocketMessage>[];

  /// The texts the client sent, oldest first.
  List<String> get sentTexts => <String>[
    for (final message in sent)
      if (message case SocketText(:final text)) text,
  ];

  /// Whether the client closed it, and with which code.
  bool closedByClient = false;

  /// The code the client closed it with, or null.
  int? clientCloseCode;

  /// Whether the client cancelled its subscription to [messages].
  bool cancelled = false;

  /// How many times the client paused [messages].
  int pauseCount = 0;

  /// Whether it is open: neither side closed it.
  bool get isOpen => !_ended;

  /// Whether the client is not reading now: what [text] writes is buffered.
  bool get isPaused => _messages.isPaused;

  /// The peer sends a text frame.
  void text(String text) {
    if (!_ended) _messages.add(SocketText(text));
  }

  /// The peer sends a binary frame.
  void bytes(List<int> bytes) {
    if (!_ended) _messages.add(SocketBytes(Uint8List.fromList(bytes)));
  }

  /// The peer closes it with [code] (null: a close frame with no code).
  void closeFromPeer([int? code = 1000]) {
    if (_ended) return;
    _ended = true;
    _messages.addError(SocketClosed(code));
    unawaited(_messages.close());
  }

  /// The connection breaks with no close frame: 1006, or [error] as the socket's failure.
  void drop([Object? error]) {
    if (_ended) return;
    _ended = true;
    _messages.addError(error ?? const SocketClosed(1006));
    unawaited(_messages.close());
  }

  @override
  Stream<SocketMessage> get messages => _messages.stream;

  @override
  void sendText(String text) {
    if (_ended) throw StateError('FakeSocket: closed');
    sent.add(SocketText(text));
  }

  @override
  void sendBytes(Uint8List bytes) {
    if (_ended) throw StateError('FakeSocket: closed');
    sent.add(SocketBytes(bytes));
  }

  /// Records the client's close; its [messages] end with no [SocketClosed], as a real socket's do.
  @override
  Future<void> close([int? code, String? reason]) async {
    if (_ended) return;
    _ended = true;
    closedByClient = true;
    clientCloseCode = code;
    unawaited(_messages.close());
  }

  @override
  String toString() => 'FakeSocket';
}

/// A handshake a [FakeSocketConnector] holds: the test answers it with [open] or [fail].
final class FakeSocketHandshake {
  FakeSocketHandshake._(
    this._connector,
    this.url,
    this.protocols,
    this.headers,
  );

  final FakeSocketConnector _connector;
  final Completer<StreamSocket> _answer = Completer<StreamSocket>();

  /// The URL being opened.
  final Uri url;

  /// The subprotocols offered.
  final List<String> protocols;

  /// The handshake's headers.
  final Map<String, String> headers;

  /// Whether it was answered.
  bool get isAnswered => _answer.isCompleted;

  /// Opens the socket, and answers it.
  FakeSocket open({String protocol = ''}) {
    final socket = _connector._socket(url, protocols, headers, protocol);
    _answer.complete(socket);
    return socket;
  }

  /// Fails the handshake with [error] (a `WebSocketException`, say).
  void fail(Object error) => _answer.completeError(error);
}

/// A [SocketConnector] for tests (since 0.25.0): each connect opens a [FakeSocket] at once, unless
/// the test scripted a failure ([fail]) or a handshake it answers itself ([hang]). It starts no
/// timer and listens to nothing.
final class FakeSocketConnector implements SocketConnector {
  /// A connector with nothing scripted.
  FakeSocketConnector();

  final Queue<Object> _script = Queue<Object>();
  final List<FakeSocket> _sockets = <FakeSocket>[];
  final List<FakeSocketHandshake> _handshakes = <FakeSocketHandshake>[];
  int _connects = 0;

  /// How many connects were asked for.
  int get connectCount => _connects;

  /// The sockets opened so far, oldest first.
  List<FakeSocket> get sockets => List<FakeSocket>.unmodifiable(_sockets);

  /// The last socket opened.
  FakeSocket get current => _sockets.last;

  /// The handshakes [hang] held, oldest first.
  List<FakeSocketHandshake> get handshakes =>
      List<FakeSocketHandshake>.unmodifiable(_handshakes);

  /// The next connect fails with [error].
  void fail(Object error) => _script.add(_Fail(error));

  /// The next connect waits for the test to answer its [FakeSocketHandshake].
  void hang() => _script.add(const _Hang());

  FakeSocket _socket(
    Uri url,
    List<String> protocols,
    Map<String, String> headers,
    String protocol,
  ) {
    final socket = FakeSocket._(url, protocols, headers, protocol);
    _sockets.add(socket);
    return socket;
  }

  @override
  Future<StreamSocket> connect(
    Uri url, {
    Iterable<String> protocols = const <String>[],
    Map<String, String> headers = const <String, String>{},
  }) {
    _connects++;
    final offered = List<String>.unmodifiable(protocols);
    final sent = Map<String, String>.unmodifiable(headers);
    switch (_script.isEmpty ? null : _script.removeFirst()) {
      case _Fail(:final error):
        return Future<StreamSocket>.error(error);
      case _Hang():
        final handshake = FakeSocketHandshake._(this, url, offered, sent);
        _handshakes.add(handshake);
        return handshake._answer.future;
    }
    return Future<StreamSocket>.value(_socket(url, offered, sent, ''));
  }

  @override
  String toString() => 'FakeSocketConnector';
}
