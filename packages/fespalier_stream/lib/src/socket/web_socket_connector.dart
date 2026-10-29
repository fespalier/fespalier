import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket/web_socket.dart';

import 'connector.dart';
import 'web_socket_open.dart'
    if (dart.library.io) 'web_socket_open_io.dart'
    as open;

/// The [SocketConnector] over `package:web_socket` (since 0.25.0): `dart:io`'s WebSocket on
/// Android, iOS and the desktop, the browser's in a web build (dart2js and wasm alike).
///
/// [headers] go on the handshake natively (`dart:io`'s `WebSocket.connect(headers:)`); a browser
/// cannot set a handshake header, so in a web build a connect with any header fails with an
/// `ArgumentError` that names none (use a ticket in the URL: `ticketGrantor`). A URL that is not
/// `ws:` or `wss:` is an `ArgumentError` too, without the URL in its text (it may hold a ticket).
/// A handshake that fails is a `WebSocketException`. No ping is sent: liveness is the app's
/// (see `SocketConnection`).
final class WebSocketConnector implements SocketConnector {
  /// The connector.
  const WebSocketConnector();

  @override
  Future<StreamSocket> connect(
    Uri url, {
    Iterable<String> protocols = const <String>[],
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (!url.isScheme('ws') && !url.isScheme('wss')) {
      throw ArgumentError(
        'WebSocketConnector: only ws: and wss: URLs can be opened',
        'url',
      );
    }
    final socket = await open.openWebSocket(
      url,
      protocols: protocols,
      headers: headers,
    );
    return _WebSocketStream(socket);
  }

  @override
  String toString() => 'WebSocketConnector';
}

/// A `package:web_socket` socket as a [StreamSocket].
final class _WebSocketStream implements StreamSocket {
  _WebSocketStream(this._socket);

  final WebSocket _socket;

  @override
  late final Stream<SocketMessage> messages = _socket.events.transform(
    StreamTransformer<WebSocketEvent, SocketMessage>.fromHandlers(
      handleData: (event, sink) {
        switch (event) {
          case TextDataReceived(:final text):
            sink.add(SocketText(text));
          case BinaryDataReceived(:final data):
            sink.add(SocketBytes(data));
          case CloseReceived(:final code):
            // The reason's text is dropped here: nothing after this point can keep it.
            sink.addError(SocketClosed(code));
        }
      },
    ),
  );

  @override
  String get protocol => _socket.protocol;

  @override
  void sendText(String text) => _socket.sendText(text);

  @override
  void sendBytes(Uint8List bytes) => _socket.sendBytes(bytes);

  @override
  Future<void> close([int? code, String? reason]) async {
    try {
      await _socket.close(code, reason);
    } on WebSocketConnectionClosed {
      // Closed already, by either side.
    }
  }

  @override
  String toString() => 'StreamSocket';
}
