/// What tests use from fespalier_stream (since 0.25.0): [FakeEventServer], an `HttpTransport` that
/// serves event streams the test writes to; [ManualStreamTicker], a tick fired by hand;
/// [FakeLiveConnection], a connection the test drives; and [streamTestOverrides].
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_transport/fespalier_transport.dart';

import 'fespalier_stream.dart';

export 'package:fespalier_stream/fespalier_stream.dart';

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
