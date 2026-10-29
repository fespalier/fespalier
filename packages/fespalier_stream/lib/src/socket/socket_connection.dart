import 'dart:async';

import 'package:fespalier/fespalier.dart' show DataRefusal;

import '../telemetry.dart';
import '../wire/live_connection.dart';
import '../wire/live_status.dart';
import 'connector.dart';
import 'grant.dart';
import 'socket_source.dart';

/// A WebSocket held as a live connection (since 0.25.0): a `LiveConnection<SocketMessage>`, so a
/// `LiveFeed` or `ChangeFeed.live` holds it as it holds `ServerEvents`.
///
/// ```dart
/// final chatConnection = Provider.autoDispose<SocketConnection>((ref) {
///   final connection = SocketConnection(
///     const WebSocketConnector(),
///     Uri.parse('wss://api.example.com/chat'),
///     grantor: ticketGrantor(ref.watch(apiTransport), Uri.parse('https://api.example.com/ws-ticket')),
///     onOpen: (socket) => socket.sendText('{"subscribe":"room-1"}'),
///     name: 'chat',
///   );
///   ref.onDispose(connection.close);
///   return connection;
/// });
/// final chat = LiveFeed<SocketMessage>((ref, _) => ref.watch(chatConnection));
/// ```
///
/// It opens when [events] is listened to: [grantor] (a `ticketGrantor`, usually) is asked once
/// per attempt for the URL, protocols and headers to connect with, the [connector] connects, and
/// [onOpen] runs with the socket on every open, the first and each reopen (the app's subscribe
/// messages: a server forgets them with the socket), before the status says [LiveOpen]. Then each
/// message the peer sends is an event.
///
/// The rules are `ServerEvents`' (no timer, no backoff, no retry), with what a socket changes:
///
/// - every close or failure makes it [LiveWaiting] (`ended` for 1000 or 1001, `unavailable` for
///   1012, 1013 or 1014, `failed` otherwise, and for a grant or a handshake that failed) and it
///   never reopens by itself: the next open is a `reconnectOn` signal, or the app's tick;
/// - it cannot resume ([lastEventId] is always null): a live change feed reads each reopen as a
///   gap, and every watched key moves once;
/// - a pause stops delivering, and the socket buffers what arrives (a WebSocket has no
///   backpressure) until a resume delivers it or the tick's `closeIfPaused` closes the socket;
/// - [lastSeen] moves with each message only (a ping frame is not seen in Dart, nor in a
///   browser): `LiveRules.idle` wants the server to send a message of its own while it has nothing
///   to say, or the app to send one from its tick that the server answers;
/// - a refusal the grantor throws (a `DataRefusal`: `SocketTicketRefused`, a session that ended)
///   ends [events] with it; an `Error` (headers in a browser, a URL that is not `ws:` or `wss:`)
///   ends it with that error.
///
/// [send] sends a message while a socket is open. [name] (`[a-z][a-z0-9_]*`) is what telemetry
/// reports: `fespalier.stream.open` and `fespalier.stream.close` with `fespalier.stream.kind`
/// `websocket`, and `fespalier.stream.close_code`; never the URL, a message or a close reason.
final class SocketConnection implements LiveConnection<SocketMessage> {
  /// A connection to [url] through [connector].
  SocketConnection(
    SocketConnector connector,
    Uri url, {
    SocketGrantor? grantor,
    Iterable<String> protocols = const <String>[],
    Map<String, String> headers = const <String, String>{},
    FutureOr<void> Function(StreamSocket socket)? onOpen,
    this.name,
  }) : assert(
         isTelemetryName(name),
         'SocketConnection name must match [a-z][a-z0-9_]*: telemetry reports it',
       ) {
    _source = SocketSource(
      connector,
      url,
      hooks: _Hooks(name),
      grantor: grantor,
      protocols: protocols,
      headers: headers,
      onOpen: onOpen,
    );
  }

  late final SocketSource _source;

  /// The name telemetry reports (`fespalier.stream.name`), or null.
  final String? name;

  /// The URL the grantor is asked for (and connected to without one).
  Uri get url => _source.url;

  /// The close code the peer sent when it last closed a socket of this connection (1006 for one
  /// that broke), or null: a server's own code (3000 to 4999) is the app's to read.
  int? get lastCloseCode => _source.lastCloseCode;

  /// Sends [message] on the open socket. Throws a `StateError` unless a socket is open: [status]
  /// is [LiveOpen], or [LivePaused] with `connected` (Riverpod pauses a feed briefly while it
  /// rebuilds). Inside `onOpen`, send on the socket it is given.
  void send(SocketMessage message) => _source.send(message);

  @override
  Stream<SocketMessage> get events => _source.events;

  @override
  LiveStatus get status => _source.status;

  @override
  Stream<LiveStatus> get statusChanges => _source.statusChanges;

  @override
  DateTime? get lastSeen => _source.lastSeen;

  /// Always null: a WebSocket cannot resume.
  @override
  String? get lastEventId => null;

  @override
  bool reconnect() => _source.reconnect();

  @override
  bool closeIfIdle(Duration limit) => _source.closeIfIdle(limit);

  @override
  bool closeIfPaused() => _source.closeIfPaused();

  @override
  Future<void> close() => _source.close();

  @override
  String toString() => 'SocketConnection($status)';
}

final class _Hooks implements SocketSourceHooks {
  _Hooks(this.name);

  final String? name;

  @override
  bool isRefusal(Object error) => error is DataRefusal;

  @override
  Object? reportOpenStart() => reportStreamOpenStart(
    name: name,
    resumed: null,
    kind: FespalierStreamConventions.kindWebSocket,
  );

  @override
  void reportOpenEnd(Object? token, String result) =>
      reportStreamOpenEnd(token, result);

  @override
  void reportClose(String reason, int messages, {int? closeCode}) =>
      reportStreamClose(
        name: name,
        reason: reason,
        events: messages,
        kind: FespalierStreamConventions.kindWebSocket,
        closeCode: closeCode,
      );
}
