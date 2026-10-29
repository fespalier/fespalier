import 'package:web_socket/web_socket.dart';

/// Opens [url] with `package:web_socket`'s own connect: the browser's WebSocket in a web build.
/// A browser cannot set a handshake header, so any is refused.
///
/// The browser's `WebSocket` constructor throws at once for what it cannot take (a subprotocol
/// that is not a token, a `ws:` URL from an `https:` page, a port it blocks), with a `DOMException`
/// whose text can name the URL, which may hold a ticket. That is an `ArgumentError` with a fixed
/// message here, so the connection ends with it instead of waiting for a retry that would fail
/// the same way. A handshake that fails is `package:web_socket`'s own `WebSocketException`, which
/// names nothing.
Future<WebSocket> openWebSocket(
  Uri url, {
  required Iterable<String> protocols,
  required Map<String, String> headers,
}) async {
  if (headers.isNotEmpty) {
    throw ArgumentError(
      'WebSocketConnector: a browser cannot set a header on a WebSocket handshake; '
          'put a ticket in the URL instead (ticketGrantor)',
      'headers',
    );
  }
  try {
    return await WebSocket.connect(url, protocols: protocols);
  } on WebSocketException {
    rethrow;
  } on Object {
    throw ArgumentError(
      'WebSocketConnector: the browser refused to open the WebSocket '
      '(a URL, a port or a subprotocol it cannot take)',
    );
  }
}
