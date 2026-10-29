import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import '../wire/event_source.dart' show CloseReason, OpenResult;
import '../wire/live_connection.dart';
import '../wire/live_status.dart';
import 'connector.dart';
import 'grant.dart';

/// What `SocketConnection` fills in around a [SocketSource] (since 0.25.0): which errors are
/// refusals, and its telemetry, which this layer does not import.
abstract interface class SocketSourceHooks {
  /// Whether [error], thrown by the grantor or the connector, is a refusal (a session that ended,
  /// a ticket the server refused): it ends the connection. Anything else that is an `Exception` is
  /// a passing failure.
  bool isRefusal(Object error);

  /// The start of an attempt (its grant and its handshake); the token is handed to [reportOpenEnd].
  Object? reportOpenStart();

  /// The end of the attempt [token] started: an [OpenResult].
  void reportOpenEnd(Object? token, String result);

  /// The end of a socket that was open: a [CloseReason], the messages it delivered, and the close
  /// code the peer sent, when it sent one.
  void reportClose(String reason, int messages, {int? closeCode});
}

/// One attempt: a grant, a handshake and, once open, the socket.
final class _Attempt {
  _Attempt(this.startedAt);

  /// When the attempt started (`package:clock`'s time): `closeIfIdle` gives up one that hangs.
  final DateTime startedAt;

  Object? token;
  bool openEnded = false;

  /// Completed when the connection gives the attempt up: the grantor's requests are aborted.
  final Completer<void> abort = Completer<void>();

  bool stale = false;
  bool opened = false;
  int messages = 0;
  StreamSocket? socket;
  StreamIterator<SocketMessage>? iterator;
}

/// A [SocketSender] over an open socket: `onOpen` gets this and not the socket, so it cannot
/// listen to the messages the connection reads.
final class _Sender implements SocketSender {
  _Sender(this._socket);

  final StreamSocket _socket;

  @override
  String get protocol => _socket.protocol;

  @override
  void sendText(String text) => _socket.sendText(text);

  @override
  void sendBytes(Uint8List bytes) => _socket.sendBytes(bytes);

  @override
  String toString() => 'SocketSender';
}

/// The WebSocket connection, with no Flutter, Riverpod or telemetry in it (since 0.25.0):
/// `SocketConnection` is it, with fespalier's refusals and telemetry filled in through
/// [SocketSourceHooks], and the browser harness of `just fetch-adapter` runs it as it is.
///
/// It follows `ServerEvents`' rules with a socket instead of a body: it opens when [events] is
/// listened to, asks the grantor once per attempt, connects, runs `onOpen` (the resubscribe
/// messages), then delivers each message. A close or a failure makes it [LiveWaiting] (it never
/// opens again by itself: a socket cannot resume, so the next open is the app's signal or tick);
/// a pause stops delivering and the socket buffers (a WebSocket has no backpressure) until
/// [closeIfPaused] closes it on the app's tick. It starts no timer.
final class SocketSource implements LiveConnection<SocketMessage> {
  /// A connection to [url] through [connector].
  SocketSource(
    this._connector,
    this.url, {
    required SocketSourceHooks hooks,
    SocketGrantor? grantor,
    Iterable<String> protocols = const <String>[],
    Map<String, String> headers = const <String, String>{},
    FutureOr<void> Function(SocketSender socket)? onOpen,
  }) : _hooks = hooks,
       _grantor = grantor,
       _protocols = List<String>.unmodifiable(<String>{...protocols}),
       _headers = Map<String, String>.unmodifiable(headers),
       _onOpenSocket = onOpen {
    _events = StreamController<SocketMessage>(
      onListen: _onListen,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  final SocketConnector _connector;
  final SocketSourceHooks _hooks;
  final SocketGrantor? _grantor;
  final List<String> _protocols;
  final Map<String, String> _headers;
  final FutureOr<void> Function(SocketSender socket)? _onOpenSocket;

  /// The URL the connection asks its grantor for, and connects to without one.
  final Uri url;

  late final StreamController<SocketMessage> _events;
  final Set<MultiStreamController<LiveStatus>> _watchers =
      <MultiStreamController<LiveStatus>>{};

  LiveStatus _status = const LiveConnecting(1);
  _Attempt? _attempt;
  bool _done = false;
  bool _listened = false;
  int _tries = 0;
  bool _paused = false;
  bool _pauseSeen = false;
  bool _reopenOnResume = false;
  LiveWaiting? _waiting;
  Completer<void>? _wake;
  DateTime? _lastSeen;
  int? _lastCloseCode;

  // LiveConnection

  /// The messages. A connection is **single-use**: it is listened to once, and once it has been
  /// listened to or closed, asking for [events] again throws a `StateError`. Create it where its
  /// owner is built (a feed's builder), so each build has a connection of its own.
  @override
  Stream<SocketMessage> get events {
    if (_listened || _done) {
      throw StateError(
        'SocketConnection is single-use: this one was listened to or closed already. '
        "Create it in the feed's builder (LiveFeed(connect)), not in a provider that outlives the "
        'feed, so every build of the feed opens its own connection.',
      );
    }
    return _events.stream;
  }

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

  /// Always null: a WebSocket cannot resume, so every reopen starts afresh (a live `ChangeFeed`
  /// reads it as a gap, and every watched key moves).
  @override
  String? get lastEventId => null;

  /// The close code the peer sent when it last closed a socket of this connection (1006 for one
  /// that broke, 1005 for a close with no code), or null.
  int? get lastCloseCode => _lastCloseCode;

  /// Sends [message] on the open socket.
  ///
  /// Throws a `StateError` unless a socket is open: [status] is [LiveOpen], or [LivePaused] with
  /// `connected` (Riverpod pauses a feed briefly while it rebuilds). A socket that closed before
  /// the connection read its close throws a `StateError` too. A message sent to a peer that went
  /// away without a word is lost: a WebSocket says nothing about it.
  void send(SocketMessage message) {
    final attempt = _attempt;
    final socket = attempt?.socket;
    if (_done || attempt == null || !attempt.opened || socket == null) {
      throw StateError('SocketConnection: no socket is open ($_status)');
    }
    try {
      switch (message) {
        case SocketText(:final text):
          socket.sendText(text);
        case SocketBytes(:final bytes):
          socket.sendBytes(bytes);
      }
    } on Exception {
      throw StateError('SocketConnection: the socket closed');
    }
  }

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
      // A grant or a handshake nobody answered: given up, and the connection waits.
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
    // What the socket buffered while paused goes with it: the resume opens a new one.
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
    _listened = true;
    if (!_done) _start();
  }

  void _onPause() {
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
      if (attempt.opened) _setStatus(const LiveOpen());
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

  Future<void> _run(_Attempt attempt) async {
    // Never inside the caller's call: a listen happens in a provider's build, a reconnect in a
    // signal's notification, and a grantor may read providers.
    await Future<void>.value();
    if (attempt.stale) return;
    attempt.token = _hooks.reportOpenStart();
    try {
      var target = url;
      var protocols = _protocols;
      var headers = _headers;
      final grantor = _grantor;
      if (grantor != null) {
        // Once per attempt, so a single-use ticket is fresh; its requests are aborted with it.
        final grant = await TransportZone.run(
          attempt.abort.future,
          () => grantor(url),
        );
        if (attempt.stale) {
          _endOpen(attempt, OpenResult.cancelled);
          return;
        }
        target = grant.url;
        protocols = <String>{..._protocols, ...grant.protocols}.toList();
        headers = mergeHeaders(_headers, grant.headers);
      }
      final socket = await _connector.connect(
        target,
        protocols: protocols,
        headers: headers,
      );
      if (attempt.stale) {
        _closeSocket(socket);
        _endOpen(attempt, OpenResult.cancelled);
        return;
      }
      attempt.socket = socket;
      // The app's resubscribe messages, before the connection says it is open: a live change feed
      // reloads at the open, and what changed after the reload must be subscribed to already.
      final onOpen = _onOpenSocket;
      if (onOpen != null) await onOpen(_Sender(socket));
    } catch (error, stackTrace) {
      if (attempt.stale) {
        _endOpen(attempt, OpenResult.cancelled);
        return;
      }
      final refused = _hooks.isRefusal(error);
      final unavailable =
          !refused && error is TransportStatusError && _isUnavailable(error);
      _endOpen(
        attempt,
        refused
            ? OpenResult.refused
            : unavailable
            ? OpenResult.unavailable
            : OpenResult.failed,
      );
      _abort(attempt);
      _attempt = null;
      if (refused) {
        _end(LiveEnd.refused, error: error, stackTrace: stackTrace);
      } else if (error case TransportStatusError(
        :final headers,
      ) when unavailable) {
        _dropped(
          LiveDrop.unavailable,
          retryAfter: _retryAfter(headers['retry-after']),
        );
      } else if (error is Exception) {
        _dropped(LiveDrop.failed);
      } else {
        // An Error (a URL a connector cannot take, headers in a browser) is the app's to fix: the
        // connection ends with it rather than wait for a reconnect that would fail the same way.
        _end(LiveEnd.failed, error: error, stackTrace: stackTrace);
      }
      return;
    }
    if (attempt.stale) return;
    _endOpen(attempt, OpenResult.open);
    await _read(attempt, attempt.socket!);
  }

  static bool _isUnavailable(TransportStatusError error) {
    final status = error.statusCode;
    return status == 408 || status == 429 || status >= 500;
  }

  /// `Retry-After` in seconds (an HTTP date is not read: it needs a server's clock).
  static Duration? _retryAfter(String? value) {
    final seconds = value == null ? null : int.tryParse(value.trim());
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  Future<void> _read(_Attempt attempt, StreamSocket socket) async {
    attempt.opened = true;
    _lastSeen = clock.now();
    final iterator = StreamIterator<SocketMessage>(socket.messages);
    attempt.iterator = iterator;
    _setStatus(_paused ? const LivePaused(connected: true) : const LiveOpen());
    int? closeCode;
    var closed = false;
    try {
      while (true) {
        while (_paused && !attempt.stale) {
          await (_wake ??= Completer<void>()).future;
        }
        if (attempt.stale) return;
        if (!await iterator.moveNext()) break;
        if (attempt.stale) return;
        _lastSeen = clock.now();
        if (attempt.messages++ == 0) _tries = 0;
        _events.add(iterator.current);
      }
    } on SocketClosed catch (close) {
      if (attempt.stale) return;
      closed = true;
      // A close frame with no code is 1005, as dart:io and the browsers report it.
      closeCode = close.code ?? 1005;
    } catch (_) {
      // A failure the socket reported: read as a connection that broke. Its text is not kept.
      if (attempt.stale) return;
    }
    if (attempt.stale) return;
    if (!closed) closeCode = 1006;
    _lastCloseCode = closeCode;
    final broke = closeCode == 1006;
    _giveUp(
      attempt,
      broke ? CloseReason.failed : CloseReason.ended,
      closeCode: closeCode,
    );
    _dropped(switch (closeCode) {
      1000 || 1001 || 1005 => LiveDrop.ended,
      1012 || 1013 || 1014 => LiveDrop.unavailable,
      _ => LiveDrop.failed,
    });
  }

  /// Ends the attempt's open span once.
  void _endOpen(_Attempt attempt, String result) {
    if (attempt.openEnded) return;
    attempt.openEnded = true;
    _hooks.reportOpenEnd(attempt.token, result);
  }

  static void _closeSocket(StreamSocket socket) {
    try {
      unawaited(
        socket
            .close(1000)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } on Object {
      // A socket that is closed already, or one that refuses the call: nothing to close.
    }
  }

  /// Gives [attempt] up: its grant's requests aborted, its messages no longer read, its socket
  /// closed.
  void _abort(_Attempt attempt) {
    attempt.stale = true;
    // An attempt given up before it opened (a grant or a handshake in flight) ends its open span
    // now: a handshake cannot be aborted, and its late answer only closes the socket it brings.
    if (!attempt.opened) _endOpen(attempt, OpenResult.cancelled);
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
    final socket = attempt.socket;
    if (socket != null) _closeSocket(socket);
  }

  void _giveUp(_Attempt attempt, String reason, {int? closeCode}) {
    _abort(attempt);
    if (identical(_attempt, attempt)) _attempt = null;
    if (attempt.opened) {
      _hooks.reportClose(reason, attempt.messages, closeCode: closeCode);
    }
    _wakeUp();
  }

  void _dropped(LiveDrop drop, {Duration? retryAfter}) {
    final waiting = LiveWaiting(
      drop,
      since: clock.now(),
      failures: _tries,
      retryHint: retryAfter,
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

  @override
  String toString() => 'SocketSource($_status)';
}
