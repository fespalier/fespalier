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
/// // The handle is how a page sends: it reaches whichever connection the feed holds now.
/// final chatSocket = Provider<SocketHandle>((ref) => SocketHandle());
/// final chat = LiveFeed<SocketMessage>((ref, _) {
///   final connection = SocketConnection(
///     const WebSocketConnector(),
///     Uri.parse('wss://api.example.com/chat'),
///     grantor: ticketGrantor(ref.watch(apiTransport), Uri.parse('https://api.example.com/ws-ticket')),
///     onOpen: (socket) => socket.sendText('{"subscribe":"room-1"}'),
///     name: 'chat',
///   );
///   ref.onDispose(ref.watch(chatSocket).attach(connection));
///   return connection;
/// });
/// ```
///
/// **A connection is single-use**, like the `ServerEvents` a feed's builder makes: its [events]
/// are listened to once, and the feed closes it when that build is disposed. So create it in the
/// feed's builder, never in a provider that outlives the feed (a rebuilt feed would be handed a
/// closed connection): asking a connection that was listened to or closed for its [events] throws
/// a `StateError` that says so. A [SocketHandle] is how the rest of the app sends.
///
/// It opens when [events] is listened to: [grantor] (a `ticketGrantor`, usually) is asked once
/// per attempt for the URL, protocols and headers to connect with, the [connector] connects, and
/// [onOpen] runs with a [SocketSender] on every open, the first and each reopen (the app's subscribe
/// messages: a server forgets them with the socket), before the status says [LiveOpen]. Then each
/// message the peer sends is an event. [onOpen] can only send: the connection reads the messages,
/// so waiting for a server's answer is the feed's job (read `latest`), not [onOpen]'s.
///
/// The rules are `ServerEvents`' (no timer, no backoff, no retry), with what a socket changes:
///
/// - every close or failure makes it [LiveWaiting] (`ended` for 1000, 1001 or 1005, `unavailable`
///   for 1012, 1013 or 1014, `failed` otherwise, and for a grant or a handshake that failed) and it
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
///   ends it with that error. A server that refuses the upgrade (HTTP 401 or 403) or closes with
///   1008 or a code of its own is a plain failure that waits: the app reads [lastCloseCode] and
///   stops watching.
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
    FutureOr<void> Function(SocketSender socket)? onOpen,
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
  /// that broke, 1005 for a close with no code), or null: a server's own code (3000 to 4999) is
  /// the app's to read.
  int? get lastCloseCode => _source.lastCloseCode;

  /// Sends [message] on the open socket. Throws a `StateError` unless a socket is open: [status]
  /// is [LiveOpen], or [LivePaused] with `connected` (Riverpod pauses a feed briefly while it
  /// rebuilds). Inside `onOpen`, send on the [SocketSender] it is given.
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

/// How the rest of an app sends on the socket a feed holds (since 0.25.0): a holder the feed's
/// builder registers each connection in, which always reaches the **current** one.
///
/// A connection lives and dies with its feed's build (it is single-use), so a provider that held
/// the connection itself would hand out a closed one after a rebuild. The handle does not: the
/// builder `attach`es each connection it makes and the handle forgets it when that build ends.
///
/// ```dart
/// final chatSocket = Provider<SocketHandle>((ref) => SocketHandle());
/// // in the feed's builder:   ref.onDispose(ref.watch(chatSocket).attach(connection));
/// // in a page or a ticker:   ref.read(chatSocket).send(const SocketText('{"say":"hi"}'));
/// ```
///
/// Use one handle per feed, and a `Provider.family` of them for a `LiveFeedFamily`. It holds no
/// listener, timer or message.
final class SocketHandle {
  /// An empty handle.
  SocketHandle();

  SocketConnection? _connection;

  /// The connection the feed holds now, or null while it holds none (nothing watches the feed).
  SocketConnection? get connection => _connection;

  /// Whether a socket is open now: the status is [LiveOpen], or [LivePaused] with `connected`.
  bool get isOpen => switch (_connection?.status) {
    LiveOpen() || LivePaused(connected: true) => true,
    _ => false,
  };

  /// Makes [connection] the current one, and answers what forgets it again (only if it is still
  /// the current one): `ref.onDispose(handle.attach(connection))` in the feed's builder.
  void Function() attach(SocketConnection connection) {
    _connection = connection;
    return () {
      if (identical(_connection, connection)) _connection = null;
    };
  }

  /// Sends [message] on the current connection's open socket. Throws a `StateError` when the feed
  /// holds no connection, or no socket is open (see [SocketConnection.send]): a caller that can
  /// race a reconnect catches it, or checks [isOpen].
  void send(SocketMessage message) {
    final connection = _connection;
    if (connection == null) {
      throw StateError(
        'SocketHandle: the feed holds no connection (nothing watches it)',
      );
    }
    connection.send(message);
  }

  @override
  String toString() => 'SocketHandle($_connection)';
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
