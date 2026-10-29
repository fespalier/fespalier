import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_dio/fetch.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_stream/web_socket.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;
import 'package:live/demo/live_server.dart';

/// The server to talk to: `--dart-define=LIVE_ORIGIN=http://192.168.1.20:8080` (tool/server.dart on
/// your computer). Empty, the default: the in-process demo server.
const liveOriginDefine = String.fromEnvironment('LIVE_ORIGIN');

/// Which client sends the requests to that server: `dio` (the default: Dio, with the fetch adapter in
/// a web build) or `http` (`package:http`'s `Client`, `BrowserClient` in a web build). Both stream an
/// event stream's body as it arrives on every platform.
const liveClientDefine = String.fromEnvironment(
  'LIVE_CLIENT',
  defaultValue: 'dio',
);

/// Whether the app talks to a real server.
const usesRealServer = liveOriginDefine != '';

/// How long a feed waits for a word from the server before the tick closes it and opens it again
/// (`LiveRules.idle`). tool/server.dart sends a comment on each event stream every 15 s and a ping on
/// the chat every 20 s, so a connection a NAT or a sleeping radio lost is noticed. The demo server
/// sends neither (it is in the app: nothing can lose it), so it gets none.
const Duration? liveIdle = usesRealServer ? Duration(seconds: 45) : null;

/// Where the demo server pretends to be: it reads only the path.
final demoOrigin = Uri.parse('https://live.example/');

/// The in-process demo server, for the container's life.
final liveServer = Provider<LiveServer>((ref) {
  final server = LiveServer();
  ref.onDispose(server.close);
  return server;
});

/// The origin every URL of the app is resolved against (`origin.resolve('orders/1/events')`).
final liveOrigin = Provider<Uri>((ref) => demoOrigin);

/// What every request, every event stream and the chat's ticket go through: the demo server, or a
/// real transport ([liveWiring]). A real app puts its session and its other decorators around it.
final liveTransport = Provider<HttpTransport>((ref) => ref.watch(liveServer));

/// What the chat's WebSocket opens through: the demo server, or [WebSocketConnector].
final liveConnector = Provider<SocketConnector>((ref) => ref.watch(liveServer));

/// The overrides that point the app at `LIVE_ORIGIN`, or none for the demo server.
List<Override> liveWiring() {
  if (!usesRealServer) return const [];
  return [
    liveOrigin.overrideWithValue(originOf(liveOriginDefine)),
    liveTransport.overrideWithValue(_transport()),
    liveConnector.overrideWithValue(const WebSocketConnector()),
  ];
}

/// [text] as an origin to resolve paths against: `http://host:8080` and `http://host:8080/` alike.
Uri originOf(String text) {
  final uri = Uri.parse(text.trim());
  return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
}

/// The chat's WebSocket URL on [origin]: `ws:` for `http:`, `wss:` for `https:`.
Uri chatUrlOf(Uri origin) => origin
    .replace(scheme: origin.isScheme('https') ? 'wss' : 'ws')
    .resolve('chat');

HttpTransport _transport() => switch (liveClientDefine) {
  'http' => HttpClientTransport(http.Client()),
  // A feed's Dio leaves receiveTimeout unset: Dio would drop an event stream that is quiet that long.
  _ => DioTransport(Dio()..httpClientAdapter = webStreamingAdapter()),
};
