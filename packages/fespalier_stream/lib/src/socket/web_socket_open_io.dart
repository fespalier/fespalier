import 'dart:io' as io;

import 'package:web_socket/io_web_socket.dart';
import 'package:web_socket/web_socket.dart';

/// Opens [url] with `dart:io`'s WebSocket, which can set [headers] on the handshake, and hands it
/// to `package:web_socket` as an `IOWebSocket`.
Future<WebSocket> openWebSocket(
  Uri url, {
  required Iterable<String> protocols,
  required Map<String, String> headers,
}) async {
  final asked = protocols.toList();
  final io.WebSocket socket;
  try {
    socket = await io.WebSocket.connect(
      url.toString(),
      protocols: asked.isEmpty ? null : asked,
      headers: headers.isEmpty ? null : headers,
    );
  } on Exception {
    // A WebSocketException, a SocketException, a HandshakeException: dart:io's text can name the
    // URL, which may hold a ticket, so it is not kept.
    throw WebSocketException('the WebSocket handshake failed');
  }
  final chosen = socket.protocol;
  if (chosen != null && !asked.contains(chosen)) {
    // dart:io does not check the peer's choice (dart-lang/sdk#55106); package:web_socket does.
    await socket.close(1002);
    throw WebSocketException('the peer chose a protocol that was not offered');
  }
  return IOWebSocket.fromWebSocket(socket);
}
