import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'event_stream_decoder.dart';
import 'live_connection.dart';
import 'live_status.dart';
import 'server_event.dart';

/// The result attribute values of a connection's open span (since 0.25.0).
abstract final class OpenResult {
  /// The server answered with an event stream.
  static const String open = 'open';

  /// 204: nothing to stream.
  static const String done = 'done';

  /// A 4xx other than 408 and 429, or a decorator's refusal.
  static const String refused = 'refused';

  /// Something that is not an event stream answered.
  static const String rejected = 'rejected';

  /// 408, 429 or a 5xx.
  static const String unavailable = 'unavailable';

  /// No answer came back.
  static const String failed = 'failed';

  /// The connection was closed before the answer came.
  static const String cancelled = 'cancelled';
}

/// The reason attribute values of a connection's close span (since 0.25.0).
abstract final class CloseReason {
  /// The server ended the body.
  static const String ended = 'ended';

  /// The body broke while it was read.
  static const String failed = 'failed';

  /// `closeIfIdle` closed it.
  static const String idle = 'idle';

  /// `closeIfPaused` closed it.
  static const String paused = 'paused';

  /// The app closed it, or its listener went away (a feed that was disposed or rebuilt).
  static const String cancelled = 'cancelled';
}

/// How long a connection must have been open for an orderly end of its body to count as one that
/// lasted: a shorter one that ends in an orderly way is a quick end.
const Duration _quickEnd = Duration(seconds: 1);

/// One request and, once the headers are in, its body.
final class _Attempt {
  _Attempt(this.startedAt);

  /// When the request was started (`package:clock`'s time): `closeIfIdle` gives up an attempt
  /// that was not answered for too long.
  final DateTime startedAt;

  /// When the headers came in, null before.
  DateTime? openedAt;

  /// The telemetry token of the open span, and whether that span has ended already.
  Object? token;
  bool openEnded = false;

  /// Completed by the connection, and only by it: an error the body ends with afterwards is the
  /// client's own (an aborted request), never a drop.
  final Completer<void> abort = Completer<void>();

  /// Whether the connection gave this attempt up (closed, replaced, idle, paused).
  bool stale = false;

  bool opened = false;
  bool resumed = false;
  int events = 0;
  StreamIterator<EventStreamItem>? iterator;
}

/// What `ServerEvents` fills in around an [EventSource] (since 0.25.0): fespalier's errors and its
/// telemetry, which the wire layer does not import.
abstract interface class EventSourceHooks {
  /// The error `events` ends with when the server refused with [statusCode].
  Object refusedError(int statusCode);

  /// The error `events` ends with when something other than an event stream answered.
  Object rejectedError({int? statusCode, String? contentType});

  /// The error the simple form's `events` ends with on a 408, 429 or 5xx.
  Object unavailableError(int statusCode, Duration? retryAfter);

  /// Whether [error], thrown by the transport, is a refusal (a session that ended): it ends the
  /// connection. Anything else that is an `Exception` is a passing failure.
  bool isRefusal(Object error);

  /// The start of a request; the returned token is handed to [reportOpenEnd].
  Object? reportOpenStart({required bool resumed});

  /// The answer to the request [token] started: an [OpenResult], and the status when one came.
  void reportOpenEnd(Object? token, String result, {int? statusCode});

  /// The end of a connection that was open: a [CloseReason], and the events it delivered.
  void reportClose(String reason, int events);
}

/// The server-sent events connection, with no Flutter, Riverpod or telemetry in it (since 0.25.0):
/// `ServerEvents` is it, with fespalier's errors and telemetry filled in through [EventSourceHooks].
///
/// Every request goes through the [HttpTransport] it was given, so the app's decorators see it:
/// a `GET` with `Accept: text/event-stream`, `Cache-Control: no-cache` and, when it resumes,
/// `Last-Event-ID`. Every attempt is a new logical request, with a `TransportMemo` of its own, and
/// carries an `abortTrigger` that the connection completes whenever it gives the attempt up:
/// cancelling a body is not enough to close a connection with every client (Dio keeps reading).
/// It reads the body through a `StreamIterator`, so a pause stops reading (the chunk it was
/// waiting for is still read and held, nothing after it), and it starts no timer: whatever waits,
/// waits for a call.
final class EventSource implements LiveConnection<ServerEvent> {
  /// A connection to [url] through [transport].
  EventSource(
    this._transport,
    this.url, {
    required EventSourceHooks hooks,
    Map<String, String> headers = const <String, String>{},
    String? lastEventId,
    int maxEventBytes = 1 << 20,
    Map<String, Object?> attributes = const <String, Object?>{},
    bool endsOnDrop = false,
  }) : _hooks = hooks,
       _headers = headers,
       _lastEventId = (lastEventId == null || lastEventId.isEmpty)
           ? null
           : lastEventId,
       _deliveredId = (lastEventId == null || lastEventId.isEmpty)
           ? null
           : lastEventId,
       _maxEventBytes = maxEventBytes,
       _attributes = attributes,
       _endsOnDrop = endsOnDrop {
    _events = StreamController<ServerEvent>(
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  final HttpTransport _transport;
  final EventSourceHooks _hooks;

  /// The event stream's URL.
  final Uri url;

  final Map<String, String> _headers;
  final int _maxEventBytes;
  final Map<String, Object?> _attributes;
  final bool _endsOnDrop;

  late final StreamController<ServerEvent> _events;
  final Set<MultiStreamController<LiveStatus>> _watchers =
      <MultiStreamController<LiveStatus>>{};

  LiveStatus _status = const LiveConnecting(1);
  _Attempt? _attempt;
  bool _done = false;

  /// Orderly ends in a row of connections that were open for less than [_quickEnd] and delivered
  /// events: the first reopens at once, a second one waits for [reconnect].
  int _quickEnds = 0;

  /// How many events were added to the stream and how many the listener was handed.
  int _added = 0;
  int _handed = 0;

  /// An id set by an id-only block while events were still held: delivered with the last of them.
  bool _hasTrailingId = false;
  String? _trailingId;

  /// Tries since the last connection that delivered an event.
  int _tries = 0;

  bool _paused = false;

  /// Whether `closeIfPaused` has already seen the current pause once.
  bool _pauseSeen = false;

  /// Whether a resume opens the connection (it was closed while paused, or asked to reconnect).
  bool _reopenOnResume = false;

  /// The waiting status a resume shows again when it does not reopen.
  LiveWaiting? _waiting;

  /// Completed by a resume or a close, for a pump that waits while paused.
  Completer<void>? _wake;

  Duration? _retry;
  DateTime? _lastSeen;

  /// The last event ID read from the server: what a reconnection of this connection sends, since
  /// the events read and not yet delivered (held while paused) are still on their way.
  String? _lastEventId;

  /// The last event ID the listener was handed: what a new connection resumes from, since what
  /// was held is lost with this one.
  String? _deliveredId;

  // LiveConnection

  @override
  Stream<ServerEvent> get events => _events.stream.map((event) {
    _handed++;
    _deliveredId = event.id;
    if (_hasTrailingId && _handed == _added) {
      _hasTrailingId = false;
      _deliveredId = _trailingId;
    }
    return event;
  });

  @override
  LiveStatus get status => _status;

  @override
  Stream<LiveStatus> get statusChanges =>
      Stream<LiveStatus>.multi((controller) {
        controller.add(_status);
        if (_done) {
          controller.close();
          return;
        }
        _watchers.add(controller);
        controller.onCancel = () => _watchers.remove(controller);
      }, isBroadcast: true);

  @override
  DateTime? get lastSeen => _lastSeen;

  @override
  String? get lastEventId => _deliveredId;

  @override
  bool reconnect() {
    if (_done || !_events.hasListener) return false;
    if (_paused && _attempt == null) {
      _reopenOnResume = true;
      return false;
    }
    if (_status is! LiveWaiting) return false;
    _start();
    return true;
  }

  @override
  bool closeIfIdle(Duration limit) {
    final attempt = _attempt;
    if (_done || _paused || attempt == null) return false;
    final now = clock.now();
    if (!attempt.opened) {
      // A request nobody answered: a half-open socket, a proxy that holds the headers. It is
      // given up like a silent connection, and the connection waits to be opened again.
      if (now.difference(attempt.startedAt) < limit) return false;
      _endOpen(attempt, OpenResult.failed);
      _giveUp(attempt, CloseReason.idle);
      _dropped(LiveDrop.failed);
      return true;
    }
    final seen = _lastSeen;
    if (seen == null || now.difference(seen) < limit) return false;
    _giveUp(attempt, CloseReason.idle);
    _dropped(LiveDrop.idle);
    return true;
  }

  @override
  bool closeIfPaused() {
    final attempt = _attempt;
    if (_done || !_paused || attempt == null || !attempt.opened) {
      _pauseSeen = _paused;
      return false;
    }
    if (!_pauseSeen) {
      _pauseSeen = true;
      return false;
    }
    _giveUp(attempt, CloseReason.paused);
    _reopenOnResume = true;
    _waiting = null;
    _setStatus(const LivePaused(connected: false));
    return true;
  }

  @override
  Future<void> close() async {
    if (_done) return;
    _end(LiveEnd.closed);
  }

  // The listener.

  void _onListen() {
    // A listen after the connection ended (or was closed) opens nothing: the stream is done.
    if (!_done) _start();
  }

  void _onPause() {
    // A pause or a resume can still come between the end and the delivery of the stream's done.
    if (_done) return;
    _paused = true;
    _pauseSeen = false;
    final attempt = _attempt;
    if (attempt == null) {
      _setStatus(const LivePaused(connected: false));
    } else if (attempt.opened) {
      _setStatus(const LivePaused(connected: true));
    }
  }

  void _onResume() {
    if (_done) return;
    _paused = false;
    _pauseSeen = false;
    _wakeUp();
    final attempt = _attempt;
    if (attempt != null) {
      if (attempt.opened) _setStatus(LiveOpen(resumed: attempt.resumed));
    } else if (_reopenOnResume) {
      _start();
    } else if (_waiting case final waiting?) {
      _setStatus(waiting);
    }
  }

  void _onCancel() {
    if (_done) return;
    _end(LiveEnd.closed);
  }

  // The connection.

  void _start() {
    _reopenOnResume = false;
    _waiting = null;
    _tries++;
    final attempt = _Attempt(clock.now());
    _attempt = attempt;
    _setStatus(LiveConnecting(_tries));
    unawaited(_run(attempt));
  }

  Map<String, String> _requestHeaders(String? resumeFrom) {
    bool has(String name) =>
        _headers.keys.any((key) => key.toLowerCase() == name);
    return <String, String>{
      if (!has('accept')) 'Accept': 'text/event-stream',
      if (!has('cache-control')) 'Cache-Control': 'no-cache',
      for (final MapEntry(:key, :value) in _headers.entries)
        if (key.toLowerCase() != 'last-event-id') key: value,
      'Last-Event-ID': ?resumeFrom,
    };
  }

  Future<void> _run(_Attempt attempt) async {
    // Never inside the caller's call: a listen happens in a provider's build, a reconnect in a
    // signal's notification, and a transport may read providers.
    await Future<void>.value();
    if (attempt.stale) return;
    final resumeFrom = _lastEventId;
    final resumed = resumeFrom != null;
    attempt.token = _hooks.reportOpenStart(resumed: resumed);
    final TransportResponse response;
    try {
      response = await _transport.send(
        TransportRequest(
          method: 'GET',
          uri: url,
          headers: _requestHeaders(resumeFrom),
          abortTrigger: attempt.abort.future,
          attributes: <String, Object?>{
            ..._attributes,
            // A new logical request each time: what a session remembered about the last
            // connection (a refusal, a renewal spent) does not carry over to this one.
            TransportMemo.key: TransportMemo(),
          },
        ),
      );
    } catch (error, stackTrace) {
      if (attempt.stale) {
        _endOpen(attempt, OpenResult.cancelled);
        return;
      }
      _attempt = null;
      if (_hooks.isRefusal(error)) {
        _endOpen(attempt, OpenResult.refused);
        _end(LiveEnd.refused, error: error, stackTrace: stackTrace);
      } else if (error is Exception) {
        _endOpen(attempt, OpenResult.failed);
        _dropped(LiveDrop.failed, error: error, stackTrace: stackTrace);
      } else {
        _endOpen(attempt, OpenResult.failed);
        _end(LiveEnd.failed, error: error, stackTrace: stackTrace);
      }
      return;
    }
    if (attempt.stale) {
      _abort(attempt);
      _endOpen(attempt, OpenResult.cancelled, statusCode: response.statusCode);
      return;
    }
    final status = response.statusCode;
    final type = response.headers['content-type'];
    if (status == 200 && _isEventStream(type)) {
      _endOpen(attempt, OpenResult.open, statusCode: status);
      await _read(attempt, response, resumed);
      return;
    }
    // Any other answer ends this attempt: the body is not read, and the request is aborted so
    // the client lets the connection go.
    _abort(attempt);
    _attempt = null;
    if (status == 204) {
      _endOpen(attempt, OpenResult.done, statusCode: status);
      _end(LiveEnd.done);
    } else if (status == 408 || status == 429 || status >= 500) {
      _endOpen(attempt, OpenResult.unavailable, statusCode: status);
      final retryAfter = _retryAfter(response.headers['retry-after']);
      _dropped(
        LiveDrop.unavailable,
        retryAfter: retryAfter,
        error: _hooks.unavailableError(status, retryAfter),
      );
    } else if (status >= 400 && status < 500) {
      _endOpen(attempt, OpenResult.refused, statusCode: status);
      _end(LiveEnd.refused, error: _hooks.refusedError(status));
    } else {
      _endOpen(attempt, OpenResult.rejected, statusCode: status);
      _end(
        LiveEnd.rejected,
        error: _hooks.rejectedError(statusCode: status, contentType: type),
      );
    }
  }

  static bool _isEventStream(String? contentType) =>
      contentType != null &&
      contentType.split(';').first.trim().toLowerCase() == 'text/event-stream';

  /// `Retry-After` in seconds (an HTTP date is not read: it needs a server's clock).
  static Duration? _retryAfter(String? value) {
    final seconds = value == null ? null : int.tryParse(value.trim());
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  /// Ends the attempt's open span once.
  void _endOpen(_Attempt attempt, String result, {int? statusCode}) {
    if (attempt.openEnded) return;
    attempt.openEnded = true;
    _hooks.reportOpenEnd(attempt.token, result, statusCode: statusCode);
  }

  Future<void> _read(
    _Attempt attempt,
    TransportResponse response,
    bool resumed,
  ) async {
    attempt
      ..opened = true
      ..resumed = resumed;
    _lastSeen = attempt.openedAt = clock.now();
    final iterator = StreamIterator<EventStreamItem>(
      response.body
          .map((chunk) {
            _lastSeen = clock.now();
            return chunk;
          })
          // The last event ID outlives a connection: an event with no `id:` keeps the one this
          // connection resumed from.
          .transform(
            EventStreamDecoder(
              maxEventBytes: _maxEventBytes,
              lastEventId: _lastEventId,
            ),
          ),
    );
    attempt.iterator = iterator;
    _setStatus(
      _paused ? const LivePaused(connected: true) : LiveOpen(resumed: resumed),
    );
    Object? failure;
    StackTrace? failureTrace;
    try {
      while (true) {
        while (_paused && !attempt.stale) {
          await (_wake ??= Completer<void>()).future;
        }
        if (attempt.stale) return;
        if (!await iterator.moveNext()) break;
        if (attempt.stale) return;
        switch (iterator.current) {
          case final ServerEvent event:
            if (attempt.events++ == 0) _tries = 0;
            // The WHATWG rule: each dispatched event sets the last event ID, cleared or not.
            _lastEventId = event.id;
            _hasTrailingId = false;
            _added++;
            _events.add(event);
          case EventIdUpdate(:final id):
            // A block with an `id:` and no data dispatches nothing, but it set the last event ID.
            _lastEventId = id;
            if (_handed == _added) {
              _deliveredId = id;
            } else {
              _hasTrailingId = true;
              _trailingId = id;
            }
          case RetryHint(:final delay):
            _retry = delay;
          case Heartbeat():
            break;
        }
      }
    } catch (error, stackTrace) {
      // An error after the connection gave the attempt up is the client's own answer to the
      // abort (a ClientException, a cancelled DioException): not a drop.
      if (attempt.stale) return;
      failure = error;
      failureTrace = stackTrace;
    }
    if (attempt.stale) return;
    _giveUp(attempt, failure == null ? CloseReason.ended : CloseReason.failed);
    if (failure != null) {
      _quickEnds = 0;
      _dropped(
        LiveDrop.failed,
        error: failure is EventStreamTooLarge
            ? failure
            : TransportBroken(failure, url),
        stackTrace: failureTrace,
      );
    } else if (attempt.events > 0 && _reopensAtOnce(attempt)) {
      // An orderly end after events: open again at once, from the last event ID.
      _start();
    } else {
      if (attempt.events == 0) _quickEnds = 0;
      _dropped(LiveDrop.ended);
    }
  }

  /// Whether an orderly end of [attempt], which delivered events, reopens the connection at once.
  ///
  /// Only when the server did not ask for a delay (a `retry:` of more than zero, which the
  /// connection keeps for its life, as a browser does) and not for a second quick end in a row: a
  /// connection that ended in an orderly way less than a second after it opened is a quick end,
  /// the first one reopens at once and the next one waits for [reconnect] (a signal, or the tick
  /// once the hint has passed). A server that ends every body at once, with an in-process
  /// transport or a fast network, cannot make the connection loop.
  bool _reopensAtOnce(_Attempt attempt) {
    final openedAt = attempt.openedAt;
    final quick =
        openedAt == null || clock.now().difference(openedAt) < _quickEnd;
    _quickEnds = quick ? _quickEnds + 1 : 0;
    final retry = _retry;
    if (retry != null && retry > Duration.zero) return false;
    return _quickEnds <= 1;
  }

  /// Completes the attempt's abort trigger and cancels its body.
  void _abort(_Attempt attempt) {
    attempt.stale = true;
    if (!attempt.abort.isCompleted) attempt.abort.complete();
    final iterator = attempt.iterator;
    attempt.iterator = null;
    if (iterator != null) {
      unawaited(
        iterator.cancel().then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
  }

  /// Ends the current attempt for [reason]: aborted, reported, forgotten.
  void _giveUp(_Attempt attempt, String reason) {
    _abort(attempt);
    if (identical(_attempt, attempt)) _attempt = null;
    if (attempt.opened) _hooks.reportClose(reason, attempt.events);
    _wakeUp();
  }

  void _dropped(
    LiveDrop drop, {
    Duration? retryAfter,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_endsOnDrop) {
      if (drop == LiveDrop.ended) {
        _end(LiveEnd.done);
      } else {
        _end(LiveEnd.failed, error: error, stackTrace: stackTrace);
      }
      return;
    }
    final waiting = LiveWaiting(
      drop,
      since: clock.now(),
      failures: _tries,
      retryHint: retryAfter ?? _retry,
    );
    _waiting = waiting;
    _setStatus(_paused ? const LivePaused(connected: false) : waiting);
  }

  void _end(LiveEnd end, {Object? error, StackTrace? stackTrace}) {
    if (_done) return;
    final attempt = _attempt;
    if (attempt != null) _giveUp(attempt, CloseReason.cancelled);
    _done = true;
    _wakeUp();
    if (error != null) _events.addError(error, stackTrace);
    unawaited(_events.close());
    _setStatus(LiveDone(end));
  }

  void _wakeUp() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _setStatus(LiveStatus status) {
    if (status == _status) return;
    _status = status;
    for (final watcher in _watchers.toList()) {
      watcher.add(status);
      if (status is LiveDone) unawaited(watcher.close());
    }
    if (status is LiveDone) _watchers.clear();
  }
}
