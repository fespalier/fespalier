import 'dart:typed_data';

/// What opens a WebSocket (since 0.25.0): the port a `SocketConnection` connects through.
///
/// `WebSocketConnector` (`package:web_socket`, native and web) is the one the package ships, and
/// `FakeSocketConnector` (`package:fespalier_stream/testing.dart`) the one a test drives. A
/// WebSocket is not an HTTP request a transport can send (an upgrade cannot go through
/// `HttpTransport`): its credential comes from a `SocketGrantor`, which fetches one through the
/// transport.
abstract interface class SocketConnector {
  /// Opens a WebSocket to [url] (`ws:` or `wss:`), offering [protocols], with [headers] on the
  /// handshake where the platform can set them (not in a browser: a connector refuses them there
  /// with an `ArgumentError`).
  ///
  /// It completes when the socket is open. A handshake that fails (no answer, a refusal, a status
  /// that is not 101) completes with an `Exception`; a URL or an argument it cannot take, with an
  /// `Error`. Neither carries the URL or a header in its text.
  Future<StreamSocket> connect(
    Uri url, {
    Iterable<String> protocols = const <String>[],
    Map<String, String> headers = const <String, String>{},
  });
}

/// What `SocketConnection.onOpen` is given to send with (since 0.25.0): the open socket, without its
/// [StreamSocket.messages].
///
/// The connection owns the messages: it reads them itself, once, and a handler that listened to
/// them would take them from the connection, which would then see no message and no close. So a
/// handler can send, and nothing else. To wait for a server's answer to what it sent, read the
/// feed's messages (`LiveFeed.latest`) and act on them there.
abstract interface class SocketSender {
  /// The subprotocol the peer chose, or the empty string.
  String get protocol;

  /// Sends a text frame. Throws an `Exception` when the socket is closed (the connection then
  /// waits, `failed`).
  void sendText(String text);

  /// Sends a binary frame. Throws an `Exception` when the socket is closed.
  void sendBytes(Uint8List bytes);
}

/// An open WebSocket, as a [SocketConnector] answers it (since 0.25.0).
abstract interface class StreamSocket implements SocketSender {
  /// What the peer sends, single-subscription. It ends when the socket closes, by either side or
  /// by a failure: with a [SocketClosed] error that carries the close code first when the peer
  /// closed it (1005 when its close frame had no code) or the connection broke (1006), with nothing
  /// when this side closed it. Another
  /// error is a failure, and a `SocketConnection` reads it as one.
  ///
  /// A pause buffers: a WebSocket has no backpressure, so what arrives while the subscription is
  /// paused is held in memory until it resumes or the socket closes.
  Stream<SocketMessage> get messages;

  /// Sends a text frame. Throws an `Exception` (a `WebSocketConnectionClosed`, from
  /// `package:web_socket`) when the socket is closed.
  @override
  void sendText(String text);

  /// Sends a binary frame. Throws an `Exception` when the socket is closed.
  @override
  void sendBytes(Uint8List bytes);

  /// Closes the socket with [code] (1000, or 3000 to 4999) and [reason] (at most 123 UTF-8
  /// bytes). Closing a socket that is closed already does nothing.
  Future<void> close([int? code, String? reason]);
}

/// One message from the peer (since 0.25.0): [SocketText] or [SocketBytes]. Sealed: switch on it.
///
/// It has no `==` on purpose: Riverpod does not notify a value that is `==` the last one, and two
/// messages with the same text are two messages. `toString` prints its size, never its content.
sealed class SocketMessage {
  const SocketMessage();
}

/// A text frame (since 0.25.0).
final class SocketText extends SocketMessage {
  /// A text message.
  const SocketText(this.text);

  /// The text.
  final String text;

  @override
  String toString() => 'SocketText(${text.length} chars)';
}

/// A binary frame (since 0.25.0).
final class SocketBytes extends SocketMessage {
  /// A binary message.
  const SocketBytes(this.bytes);

  /// The bytes.
  final Uint8List bytes;

  @override
  String toString() => 'SocketBytes(${bytes.length} bytes)';
}

/// How a socket closed (since 0.25.0): what [StreamSocket.messages] ends with when the peer closed
/// it, or when the connection broke.
///
/// It carries the close code only (RFC 6455, section 7.4): the peer's reason text is never kept,
/// so it can reach neither a log nor telemetry.
class SocketClosed implements Exception {
  /// A close with [code]. A connector reports a close frame that had no code as 1005, as
  /// `dart:io` and the browsers do; a null is read the same way.
  const SocketClosed(this.code);

  /// The close code: 1000 normal, 1001 going away, 1005 a close frame with no code (an orderly
  /// close all the same), 1006 a connection that broke with no close frame, 1012 a restart, 1013
  /// try again later, 3000 to 4999 the server's own. The shipped connectors never give null.
  final int? code;

  @override
  String toString() => 'SocketClosed($code)';
}
