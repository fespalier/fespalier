/// WebSockets for fespalier (since 0.25.0), a library of its own so that an app that does not open
/// one does not import `package:web_socket`: `package:fespalier_stream/fespalier_stream.dart`
/// reaches none of it (`test/web_socket_library_test.dart` reads the imports).
///
/// - [SocketConnection] is a WebSocket as a `LiveConnection<SocketMessage>`, so a `LiveFeed` or
///   `ChangeFeed.live` holds it as it holds `ServerEvents`: no timer, a drop is `LiveWaiting`, a
///   pause buffers until the app's tick closes it, a reopen runs `onOpen` (the subscribe messages)
///   again.
/// - [SocketConnector] is the port it connects through; [WebSocketConnector] is the one over
///   `package:web_socket` (`dart:io` natively, the browser's WebSocket on the web), and
///   `FakeSocketConnector` in `package:fespalier_stream/testing.dart` the one a test drives.
/// - A WebSocket is not an HTTP request (an upgrade cannot go through `HttpTransport`), and a
///   browser cannot set a header on it: its credential is a [SocketGrant], which a
///   [SocketGrantor] fetches before each connect. [ticketGrantor] asks a ticket endpoint through
///   the app's transport chain, so its session applies, and puts the single-use ticket in the URL.
library;

export 'src/socket/connector.dart'
    show
        SocketBytes,
        SocketClosed,
        SocketConnector,
        SocketMessage,
        SocketText,
        StreamSocket;
export 'src/socket/grant.dart' show SocketGrant, SocketGrantor;
export 'src/socket/socket_connection.dart' show SocketConnection;
export 'src/socket/ticket.dart' show SocketTicketRefused, ticketGrantor;
export 'src/socket/web_socket_connector.dart' show WebSocketConnector;
