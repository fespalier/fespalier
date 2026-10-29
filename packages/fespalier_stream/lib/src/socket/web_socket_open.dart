import 'package:web_socket/web_socket.dart';

/// Opens [url] with `package:web_socket`'s own connect: the browser's WebSocket in a web build.
/// A browser cannot set a handshake header, so any is refused.
Future<WebSocket> openWebSocket(
  Uri url, {
  required Iterable<String> protocols,
  required Map<String, String> headers,
}) {
  if (headers.isNotEmpty) {
    throw ArgumentError(
      'WebSocketConnector: a browser cannot set a header on a WebSocket handshake; '
          'put a ticket in the URL instead (ticketGrantor)',
      'headers',
    );
  }
  return WebSocket.connect(url, protocols: protocols);
}
