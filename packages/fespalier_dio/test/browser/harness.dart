// The browser harness of `just fetch-adapter` (CI's `fetch-adapter` job): compiled with
// `dart compile js` and `dart compile wasm` (it imports no Flutter, so no Flutter tool builds
// it), served by tool/stream_server.dart, and driven in Chromium, Firefox and WebKit by
// ci/web-routes/fetch.mjs, which reads `window.fetchResult` once `window.fetchDone` is set.
//
// The page is opened at `/<build>/index.html?api=<origin>&run=<tag>`; every request goes to the
// api origin, another port, so each is a CORS request as an app's API call is. It checks, over
// both web transports (`DioTransport(Dio()..httpClientAdapter = FetchHttpClientAdapter())` and
// `HttpClientTransport(BrowserClient())`):
//
// - `stream`: fespalier_stream's EventSource (what ServerEvents is, without the fespalier
//   telemetry and errors that need Flutter) reads ten events written 200 ms apart, and each
//   arrives as it is written: the first within 300 ms, the ten spanning at least 1.5 s;
// - `close`: closing the connection after three events makes the server see the disconnect;
// - `headers`: the response headers come lower-cased, an exposed header included;
// - `status`: a 418 is an answer with its status, reason phrase and body;
//
// and, over fespalier_stream's WebSocketConnector (since 0.25.0, the browser's WebSocket through
// package:web_socket), `socket`: a header on the handshake is refused (`ArgumentError`), so is a
// subprotocol the browser throws on (an `ArgumentError` that names no URL), and its
// SocketSource (what SocketConnection is, without the fespalier telemetry and refusals that need
// Flutter) connects with a grant (a ticket in the query, a subprotocol), runs onOpen, receives text
// and bytes, sends both, waits after the server closes with 4001 (the code, never the reason),
// replays onOpen on the reconnect, and closes with 1000, which the server sees;
//
// and, for the fetch adapter alone: cancelling the body subscription, Dio's CancelToken (after
// and before the headers) and `close(force: true)` abort the request; a cancel while the request
// body is still being read cancels its source; a port nothing listens on is a connection error
// (`TransportUnsent` through DioTransport); a request the browser refuses to build is `unknown`,
// not a connection error; a POST body arrives whole; Dio's `receiveTimeout` drops a quiet stream
// and `Duration.zero` (or no timeout) lets it stream; and `withCredentials` (and
// `Options.extra['withCredentials']`) choose the request's credentials.
//
// The page also draws a table of the cases and a last line, `all passed` or `N failed`, so it can
// be opened by hand (`just fetch-adapter-serve`), in Safari for one.
//
// It is test code: it reads the clock and waits, which lib/ never does.
// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier_dio/fetch.dart';
import 'package:fespalier_dio/src/dio_transport.dart';
import 'package:fespalier_http/src/http_client_transport.dart';
import 'package:fespalier_stream/src/socket/connector.dart';
import 'package:fespalier_stream/src/socket/grant.dart';
import 'package:fespalier_stream/src/socket/socket_source.dart';
import 'package:fespalier_stream/src/socket/web_socket_connector.dart';
import 'package:fespalier_stream/src/wire/event_source.dart';
import 'package:fespalier_stream/src/wire/live_status.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;

late final Uri _api;
late final String _run;
var _serial = 0;

/// A connection id the server's log is read by.
String _id(String name) => '$_run-$name-${_serial++}';

int _now() => DateTime.now().millisecondsSinceEpoch;

/// A failed check, with what was seen.
final class _Failed implements Exception {
  _Failed(this.message);
  final String message;
  @override
  String toString() => message;
}

void _expect(bool ok, String what) {
  if (!ok) throw _Failed(what);
}

/// The server's log for [id], once a line starting with [prefix] is in it, or what it had after
/// three seconds.
Future<List<String>> _serverSaw(String id, String prefix) async {
  final until = _now() + 3000;
  while (true) {
    final response = await web.window
        .fetch(
          _api
              .replace(path: '/log', queryParameters: {'id': id})
              .toString()
              .toJS,
        )
        .toDart;
    final text = (await response.text().toDart).toDart;
    final lines = [
      for (final line in jsonDecode(text) as List<Object?>) '$line',
    ];
    if (lines.any((l) => l.startsWith(prefix)) || _now() > until) return lines;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Counts the `id:` blocks in [chunks]: [reached] completes when [wanted] have arrived, or fails
/// when the stream errors or ends first, so a case reports its row instead of waiting for ever.
/// [onEnd] sees how the stream ended (the error, or null).
({StreamSubscription<List<int>> subscription, Future<void> reached})
_untilEvents(
  Stream<List<int>> chunks,
  int wanted, {
  void Function(Object? error)? onEnd,
}) {
  var events = 0;
  final reached = Completer<void>();
  final subscription = chunks.listen(
    (chunk) {
      events += utf8
          .decode(chunk)
          .split('\n\n')
          .where((b) => b.startsWith('id:'))
          .length;
      if (events >= wanted && !reached.isCompleted) reached.complete();
    },
    onError: (Object error) {
      onEnd?.call(error);
      if (!reached.isCompleted) reached.completeError(error);
    },
    onDone: () {
      onEnd?.call(null);
      if (!reached.isCompleted) {
        reached.completeError(_Failed('the stream ended after $events events'));
      }
    },
  );
  return (subscription: subscription, reached: reached.future);
}

/// fespalier_stream's hooks, filled with plain errors and no telemetry.
final class _Hooks implements EventSourceHooks {
  @override
  Object refusedError(int statusCode) => _Failed('refused $statusCode');
  @override
  Object rejectedError({int? statusCode, String? contentType}) =>
      _Failed('rejected $statusCode $contentType');
  @override
  Object unavailableError(int statusCode, Duration? retryAfter) =>
      _Failed('unavailable $statusCode');
  @override
  bool isRefusal(Object error) => false;
  @override
  Object? reportOpenStart({required bool resumed}) => null;
  @override
  void reportOpenEnd(Object? token, String result, {int? statusCode}) {}
  @override
  void reportClose(String reason, int events) {}
}

/// Ten events through [transport]: when each was written and when it arrived.
Future<Map<String, Object?>> _stream(HttpTransport transport) async {
  final id = _id('stream');
  final source = EventSource(
    transport,
    _api.replace(path: '/sse', queryParameters: {'id': id}),
    hooks: _Hooks(),
    endsOnDrop: true,
  );
  final arrivals = <List<int>>[];
  await for (final event in source.events) {
    final data = jsonDecode(event.data) as Map<String, Object?>;
    arrivals.add([data['t']! as int, _now()]);
  }
  _expect(arrivals.length == 10, '${arrivals.length} events, not 10');
  final first = arrivals.first[1] - arrivals.first[0];
  final span = arrivals.last[1] - arrivals.first[1];
  final worst = arrivals
      .map((a) => a[1] - a[0])
      .reduce((a, b) => a > b ? a : b);
  final result = {'first': first, 'span': span, 'worst': worst};
  _expect(first <= 300, 'the first event came $first ms after it was written');
  _expect(span >= 1500, 'the ten events arrived within $span ms: buffered');
  _expect(source.lastEventId == '10', 'last event id ${source.lastEventId}');
  return result;
}

/// Three events, then the connection is closed: the server must see it go.
Future<Map<String, Object?>> _close(HttpTransport transport) async {
  final id = _id('close');
  final source = EventSource(
    transport,
    _api.replace(path: '/sse', queryParameters: {'id': id}),
    hooks: _Hooks(),
  );
  var seen = 0;
  final three = Completer<void>();
  final subscription = source.events.listen(
    (_) {
      if (++seen == 3 && !three.isCompleted) three.complete();
    },
    onError: (Object error) {
      if (!three.isCompleted) three.completeError(error);
    },
    onDone: () {
      if (!three.isCompleted) {
        three.completeError(_Failed('the stream ended after $seen events'));
      }
    },
  );
  await three.future;
  await subscription.cancel();
  final log = await _serverSaw(id, 'closed');
  _expect(log.contains('closed $id after 3'), 'the server saw $log');
  return {'server': log};
}

/// The headers of an event stream, then an abort before its first event.
Future<Map<String, Object?>> _headers(HttpTransport transport) async {
  final id = _id('headers');
  final abort = Completer<void>();
  final response = await transport.send(
    TransportRequest(
      method: 'GET',
      uri: _api.replace(path: '/sse', queryParameters: {'id': id}),
      headers: const {'accept': 'text/event-stream'},
      abortTrigger: abort.future,
    ),
  );
  abort.complete();
  unawaited(response.body.drain<void>().catchError((Object _) {}));
  final headers = response.headers;
  _expect(response.statusCode == 200, 'status ${response.statusCode}');
  _expect(
    headers.keys.every((k) => k == k.toLowerCase()),
    'header names ${headers.keys}',
  );
  _expect(
    headers['content-type']?.startsWith('text/event-stream') ?? false,
    'content-type ${headers['content-type']}',
  );
  _expect(headers['x-fespalier-probe'] == 'sse', 'headers $headers');
  final log = await _serverSaw(id, 'closed');
  _expect(log.any((l) => l.startsWith('closed $id')), 'the server saw $log');
  return {'headers': headers.keys.toList()..sort()};
}

/// A 418 is an answer: its status, reason phrase and body.
Future<Map<String, Object?>> _status(HttpTransport transport) async {
  final response = await transport.send(
    TransportRequest(
      method: 'GET',
      uri: _api.replace(path: '/status', queryParameters: {'code': '418'}),
    ),
  );
  final body = await utf8.decodeStream(response.body);
  _expect(response.statusCode == 418, 'status ${response.statusCode}');
  _expect(response.reasonPhrase == 'Probe', 'reason ${response.reasonPhrase}');
  _expect(body == 'status 418', 'body $body');
  _expect(response.headers['x-fespalier-probe'] == 'status', 'headers');
  return {'status': response.statusCode};
}

/// The fetch adapter alone: its body, cancelled after three events.
Future<Map<String, Object?>> _bodyCancel() async {
  final id = _id('body-cancel');
  final adapter = FetchHttpClientAdapter();
  final body = await adapter.fetch(
    RequestOptions(
      path: _api.replace(path: '/sse', queryParameters: {'id': id}).toString(),
    ),
    null,
    null,
  );
  final (:subscription, :reached) = _untilEvents(body.stream, 3);
  await reached;
  await subscription.cancel();
  final log = await _serverSaw(id, 'closed');
  _expect(log.contains('closed $id after 3'), 'the server saw $log');
  return {'server': log};
}

/// Dio with the fetch adapter: its CancelToken, after three events.
Future<Map<String, Object?>> _cancelToken() async {
  final id = _id('cancel-token');
  final dio = Dio()..httpClientAdapter = FetchHttpClientAdapter();
  final token = CancelToken();
  final response = await dio.getUri<ResponseBody>(
    _api.replace(path: '/sse', queryParameters: {'id': id}),
    cancelToken: token,
    options: Options(responseType: ResponseType.stream),
  );
  Object? error;
  final done = Completer<void>();
  final (:subscription, :reached) = _untilEvents(
    response.data!.stream,
    3,
    onEnd: (e) {
      error ??= e;
      if (!done.isCompleted) done.complete();
    },
  );
  await reached;
  token.cancel('enough');
  final log = await _serverSaw(id, 'closed');
  _expect(log.contains('closed $id after 3'), 'the server saw $log');
  await done.future;
  await subscription.cancel();
  return {
    'server': log,
    'bodyError': switch (error) {
      DioException(:final type) => type.name,
      final other => '$other',
    },
  };
}

/// The fetch adapter: `close(force: true)` aborts what is open, and the body ends with a cancel.
Future<Map<String, Object?>> _closeForce() async {
  final id = _id('close-force');
  final adapter = FetchHttpClientAdapter();
  final body = await adapter.fetch(
    RequestOptions(
      path: _api.replace(path: '/sse', queryParameters: {'id': id}).toString(),
    ),
    null,
    null,
  );
  final ended = Completer<Object?>();
  final (:subscription, :reached) = _untilEvents(
    body.stream,
    3,
    onEnd: (e) {
      if (!ended.isCompleted) ended.complete(e);
    },
  );
  await reached;
  adapter.close(force: true);
  final error = await ended.future;
  await subscription.cancel();
  _expect(
    error is DioException && error.type == DioExceptionType.cancel,
    'the body ended with $error',
  );
  final log = await _serverSaw(id, 'closed');
  _expect(log.contains('closed $id after 3'), 'the server saw $log');
  return {'server': log};
}

/// Dio with the fetch adapter: a CancelToken before the headers came.
Future<Map<String, Object?>> _cancelEarly() async {
  final id = _id('cancel-early');
  final dio = Dio()..httpClientAdapter = FetchHttpClientAdapter();
  final token = CancelToken();
  final request = dio.getUri<String>(
    _api.replace(path: '/slow', queryParameters: {'id': id}),
    cancelToken: token,
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  token.cancel('early');
  DioExceptionType? type;
  try {
    await request;
  } on DioException catch (e) {
    type = e.type;
  }
  _expect(type == DioExceptionType.cancel, 'the request ended with $type');
  final log = await _serverSaw(id, 'closed');
  _expect(log.contains('closed $id before headers'), 'the server saw $log');
  return {'server': log};
}

/// A port nothing listens on: a connection error, `TransportUnsent` through DioTransport.
Future<Map<String, Object?>> _unsent(int deadPort) async {
  final uri = _api.replace(port: deadPort, path: '/sse');
  final dio = Dio()..httpClientAdapter = FetchHttpClientAdapter();
  DioExceptionType? type;
  try {
    await dio.getUri<String>(uri);
  } on DioException catch (e) {
    type = e.type;
  }
  _expect(type == DioExceptionType.connectionError, 'Dio threw $type');
  Object? failure;
  try {
    await DioTransport(dio).send(TransportRequest(method: 'GET', uri: uri));
  } on Object catch (e) {
    failure = e;
  }
  _expect(
    failure is TransportUnsent,
    'DioTransport threw ${failure.runtimeType}',
  );
  return {
    'dio': type?.name,
    'transport': failure is TransportUnsent ? 'TransportUnsent' : '$failure',
  };
}

/// Everything [body] says: its text, and the error it ended with, if any.
Future<({String text, Object? error})> _drain(Stream<List<int>> body) async {
  final text = StringBuffer();
  Object? error;
  try {
    await for (final chunk in body) {
      text.write(utf8.decode(chunk));
    }
  } on Object catch (e) {
    error = e;
  }
  return (text: '$text', error: error);
}

/// Dio's `receiveTimeout` is Dio's own, on this adapter as on every other: it drops a stream that
/// is quiet for that long (a `receiveTimeout` error in the body, `DioTransport` handing it on as
/// it is). `Options(receiveTimeout: Duration.zero)`, or no timeout, lets the stream be quiet.
Future<Map<String, Object?>> _receiveTimeout() async {
  Uri quiet(String name) => _api.replace(
    path: '/quiet',
    queryParameters: {'id': _id('receive-timeout-$name')},
  );
  Dio dio({Duration? receive}) =>
      Dio(BaseOptions(receiveTimeout: receive))
        ..httpClientAdapter = FetchHttpClientAdapter();
  const short = Duration(milliseconds: 300);
  const streaming = ResponseType.stream;

  // The Dio has a short receive timeout: the quiet stream fails with it.
  final timedUri = quiet('dio');
  final timed = await dio(
    receive: short,
  ).getUri<ResponseBody>(timedUri, options: Options(responseType: streaming));
  final dropped = await _drain(timed.data!.stream);
  final droppedType = switch (dropped.error) {
    DioException(:final type) => type.name,
    final other => '$other',
  };
  _expect(
    droppedType == 'receiveTimeout' && !dropped.text.contains('late'),
    'a quiet stream under receiveTimeout: $droppedType, ${dropped.text}',
  );
  final log = await _serverSaw(timedUri.queryParameters['id']!, 'closed');
  _expect(
    log.any((l) => l.startsWith('closed ${timedUri.queryParameters['id']}')),
    'the server did not see the timed out stream go: $log',
  );

  // DioTransport hands the same error on in the body.
  final viaTransport = await DioTransport(
    dio(receive: short),
  ).send(TransportRequest(method: 'GET', uri: quiet('transport')));
  final transported = await _drain(viaTransport.body);
  _expect(
    transported.error is DioException &&
        (transported.error! as DioException).type ==
            DioExceptionType.receiveTimeout,
    'through DioTransport: ${transported.error}',
  );

  // Duration.zero on the request disables it, though the Dio has one.
  final zero = await dio(receive: short).getUri<ResponseBody>(
    quiet('zero'),
    options: Options(responseType: streaming, receiveTimeout: Duration.zero),
  );
  final zeroRead = await _drain(zero.data!.stream);
  _expect(
    zeroRead.error == null && zeroRead.text.contains('late'),
    'with Duration.zero: ${zeroRead.error}, ${zeroRead.text}',
  );

  // A Dio with no receive timeout streams.
  final none = await dio().getUri<ResponseBody>(
    quiet('none'),
    options: Options(responseType: streaming),
  );
  final noneRead = await _drain(none.data!.stream);
  _expect(
    noneRead.error == null && noneRead.text.contains('late'),
    'with no timeout: ${noneRead.error}, ${noneRead.text}',
  );
  return {'dio': droppedType, 'zero': 'streamed', 'none': 'streamed'};
}

/// A request the browser refuses to build is `unknown`, not a connection error: a feed that
/// reconnects on `TransportUnsent` would never stop on one it can never send.
Future<Map<String, Object?>> _malformed() async {
  final dio = Dio()..httpClientAdapter = FetchHttpClientAdapter();
  Future<String> typeOf(Future<Object?> request) async {
    try {
      await request;
      return 'sent';
    } on DioException catch (e) {
      return e.type.name;
    }
  }

  final uri = _api.replace(path: '/status');
  final result = {
    'getWithBody': await typeOf(dio.getUri<String>(uri, data: 'x')),
    'userInfo': await typeOf(
      dio.getUri<String>(_api.replace(path: '/status', userInfo: 'user:pw')),
    ),
    'trace': await typeOf(
      dio.requestUri<String>(uri, options: Options(method: 'TRACE')),
    ),
  };
  for (final MapEntry(:key, :value) in result.entries) {
    _expect(value == 'unknown', '$key was $value, not unknown');
  }
  // And through DioTransport it is not an unsent request.
  Object? failure;
  try {
    await DioTransport(dio).send(
      TransportRequest(method: 'GET', uri: uri, body: Uint8List.fromList([1])),
    );
  } on Object catch (e) {
    failure = e;
  }
  _expect(
    failure is TransportBroken,
    'DioTransport threw ${failure.runtimeType}',
  );
  return {...result, 'transport': 'TransportBroken'};
}

/// A cancel while the request body is still being read stops pulling it and cancels its source.
Future<Map<String, Object?>> _cancelUpload() async {
  final cancelled = Completer<void>();
  Timer? timer;
  late final StreamController<Uint8List> source;
  source = StreamController<Uint8List>(
    onListen: () => timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => source.add(Uint8List(64)),
    ),
    onCancel: () {
      timer?.cancel();
      if (!cancelled.isCompleted) cancelled.complete();
    },
  );
  final cancel = Completer<void>();
  try {
    final outcome = FetchHttpClientAdapter()
        .fetch(
          RequestOptions(
            path: _api.replace(path: '/echo').toString(),
            method: 'POST',
          ),
          source.stream,
          cancel.future,
        )
        .then<String>(
          (_) => 'answered',
          onError: (Object e) => e is DioException ? e.type.name : '$e',
        );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    cancel.complete();
    final type = await outcome;
    _expect(type == 'cancel', 'the request ended with $type');
    await cancelled.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw _Failed('the request body was not cancelled'),
    );
    return {'request': type, 'source': 'cancelled'};
  } finally {
    timer?.cancel();
  }
}

/// A POST body arrives whole (the adapter reads it into memory before it sends it).
Future<Map<String, Object?>> _post() async {
  final sent = Uint8List.fromList([for (var i = 0; i < 4096; i++) i % 256]);
  final response =
      await DioTransport(
        Dio()..httpClientAdapter = FetchHttpClientAdapter(),
      ).send(
        TransportRequest(
          method: 'POST',
          uri: _api.replace(path: '/echo'),
          headers: const {'content-type': 'application/octet-stream'},
          body: sent,
        ),
      );
  final back = await response.body.fold<List<int>>(
    <int>[],
    (all, c) => all..addAll(c),
  );
  _expect(response.statusCode == 200, 'status ${response.statusCode}');
  _expect(back.length == sent.length, '${back.length} bytes came back');
  for (var i = 0; i < sent.length; i++) {
    _expect(back[i] == sent[i], 'byte $i differs');
  }
  return {'bytes': back.length};
}

/// `withCredentials` reaches the request: a credentialed request must refuse an answer that
/// allows any origin (`*`), and one without credentials accepts it.
Future<Map<String, Object?>> _credentials() async {
  Future<String> outcome(
    FetchHttpClientAdapter adapter,
    String path, {
    bool? extra,
  }) async {
    final dio = Dio()..httpClientAdapter = adapter;
    try {
      final response = await dio.getUri<String>(
        _api.replace(path: path),
        options: Options(extra: {'withCredentials': ?extra}),
      );
      return 'ok ${response.data}';
    } on DioException catch (e) {
      return e.type.name;
    }
  }

  final plain = await outcome(FetchHttpClientAdapter(), '/cors-star');
  final credentialed = await outcome(
    FetchHttpClientAdapter(withCredentials: true),
    '/cors-star',
  );
  final allowed = await outcome(
    FetchHttpClientAdapter(withCredentials: true),
    '/status',
  );
  final perRequest = await outcome(
    FetchHttpClientAdapter(),
    '/cors-star',
    extra: true,
  );
  final perRequestOff = await outcome(
    FetchHttpClientAdapter(withCredentials: true),
    '/cors-star',
    extra: false,
  );
  final result = {
    'plain': plain,
    'credentialed': credentialed,
    'allowed': allowed,
    'perRequest': perRequest,
    'perRequestOff': perRequestOff,
  };
  _expect(plain == 'ok ok', 'without credentials: $plain');
  _expect(
    credentialed == 'connectionError',
    'with credentials, against *: $credentialed',
  );
  _expect(allowed == 'ok status 200', 'with credentials, allowed: $allowed');
  _expect(
    perRequest == 'connectionError',
    "Options.extra['withCredentials'] true: $perRequest",
  );
  _expect(
    perRequestOff == 'ok ok',
    "Options.extra['withCredentials'] false: $perRequestOff",
  );
  return result;
}

/// fespalier_stream's socket hooks, with no telemetry: nothing is a refusal.
final class _SocketHooks implements SocketSourceHooks {
  @override
  bool isRefusal(Object error) => false;
  @override
  Object? reportOpenStart() => null;
  @override
  void reportOpenEnd(Object? token, String result) {}
  @override
  void reportClose(String reason, int messages, {int? closeCode}) {}
}

/// A WebSocket to the server's `/ws`: the browser's, through package:web_socket.
Future<Map<String, Object?>> _socket() async {
  final id = _id('ws');
  final url = _api.replace(scheme: 'ws', path: '/ws');
  const connector = WebSocketConnector();

  // A browser cannot set a handshake header: refused before anything is opened.
  Object? refused;
  try {
    await connector.connect(url, headers: const {'x-device': 'phone'});
  } on ArgumentError catch (error) {
    refused = error;
  }
  _expect(refused != null, 'a header on the handshake was not refused');

  // A subprotocol the browser's constructor throws on at once (a space): an ArgumentError with a
  // fixed text, which names neither the URL nor its ticket.
  Object? badProtocol;
  try {
    await connector.connect(
      url.replace(queryParameters: {'ticket': 'tk-secret'}),
      protocols: const ['not a token'],
    );
  } on ArgumentError catch (error) {
    badProtocol = error;
  }
  _expect(
    badProtocol != null &&
        !'$badProtocol'.contains('tk-secret') &&
        !'$badProtocol'.contains(url.host),
    'a subprotocol the browser refuses was $badProtocol',
  );

  var attempt = 0;
  final opened = <String>[];
  final source = SocketSource(
    connector,
    url,
    hooks: _SocketHooks(),
    grantor: (asked) async => SocketGrant(
      asked.replace(
        queryParameters: {'id': '$id-${++attempt}', 'ticket': 'tk-$attempt'},
      ),
      protocols: const ['fsp.v1'],
    ),
    onOpen: (socket) {
      opened.add(socket.protocol);
      socket.sendText('echo:subscribed');
    },
  );
  // Read without pausing (a StreamIterator pauses between reads, and a paused connection stops
  // reading, so it would never see the server's close).
  final inbox = <String>[];
  var waiter = Completer<void>();
  final subscription = source.events.listen(
    (message) {
      inbox.add(switch (message) {
        SocketText(:final text) => text,
        SocketBytes(:final bytes) => 'bytes:${bytes.join(',')}',
      });
      if (!waiter.isCompleted) waiter.complete();
    },
    onError: (Object error) {
      if (!waiter.isCompleted) waiter.completeError(error);
    },
  );
  Future<String> next() async {
    while (inbox.isEmpty) {
      waiter = Completer<void>();
      await waiter.future;
    }
    return inbox.removeAt(0);
  }

  final first = [await next(), await next(), await next()];
  _expect(
    first.join(' ') == 'hello bytes:1,2,3 subscribed',
    'first messages $first',
  );
  _expect(opened.join() == 'fsp.v1', 'onOpen saw protocols $opened');
  source.send(const SocketText('echo:ping'));
  _expect(await next() == 'ping', 'no echo of the text');
  source.send(SocketBytes(Uint8List.fromList([7, 8])));
  _expect(await next() == 'bytes:7,8', 'no echo of the bytes');

  // The server closes with 4001 and a reason: the connection waits, and keeps the code only.
  source.send(const SocketText('close'));
  final waiting = await source.statusChanges.firstWhere(
    (s) => s is LiveWaiting,
  );
  _expect(source.lastCloseCode == 4001, 'close code ${source.lastCloseCode}');
  _expect(
    (waiting as LiveWaiting).drop == LiveDrop.failed,
    'a 4001 waits as ${waiting.drop}',
  );

  // A reconnect asks a new grant and runs onOpen again.
  _expect(source.reconnect(), 'reconnect refused');
  final again = [await next(), await next(), await next()];
  _expect(
    again.join(' ') == 'hello bytes:1,2,3 subscribed',
    'after the reconnect $again',
  );
  _expect(opened.length == 2, 'onOpen ran ${opened.length} times');
  await subscription.cancel();
  final log = await _serverSaw('$id-2', 'ws-closed');
  final firstLog = await _serverSaw('$id-1', 'ws-closed');
  _expect(
    firstLog.contains('ws-open $id-1 ticket=tk-1 protocol=fsp.v1'),
    'the server saw $firstLog',
  );
  _expect(log.contains('ws-closed $id-2 code 1000'), 'the server saw $log');
  return {
    'server': [...firstLog, ...log],
  };
}

Future<void> main() async {
  final page = Uri.parse(web.window.location.href);
  _api = Uri.parse(page.queryParameters['api']!);
  _run = page.queryParameters['run'] ?? 'run';
  final deadPort = int.parse(page.queryParameters['dead']!);
  final transports = <String, HttpTransport Function()>{
    'dio': () =>
        DioTransport(Dio()..httpClientAdapter = FetchHttpClientAdapter()),
    'http': () => HttpClientTransport(BrowserClient()),
  };
  final cases = <(String, String, Future<Map<String, Object?>> Function())>[
    for (final MapEntry(key: client, value: make) in transports.entries) ...[
      (client, 'stream', () => _stream(make())),
      (client, 'close', () => _close(make())),
      (client, 'headers', () => _headers(make())),
      (client, 'status', () => _status(make())),
    ],
    ('dio', 'body-cancel', _bodyCancel),
    ('dio', 'cancel-token', _cancelToken),
    ('dio', 'close-force', _closeForce),
    ('dio', 'cancel-early', _cancelEarly),
    ('dio', 'unsent', () => _unsent(deadPort)),
    ('dio', 'post', _post),
    ('dio', 'receive-timeout', _receiveTimeout),
    ('dio', 'malformed', _malformed),
    ('dio', 'cancel-upload', _cancelUpload),
    ('dio', 'credentials', _credentials),
    ('ws', 'socket', _socket),
  ];
  _draw();
  final results = <Map<String, Object?>>[];
  for (final (client, name, run) in cases) {
    final started = _now();
    Map<String, Object?> row;
    try {
      // One case that hangs reports its own row, not a timeout of the whole page.
      row = {
        'ok': true,
        ...await run().timeout(
          _caseTimeout,
          onTimeout: () =>
              throw _Failed('no answer after ${_caseTimeout.inSeconds} s'),
        ),
      };
    } on Object catch (error) {
      row = {'ok': false, 'error': '$error'};
    }
    final result = {
      'client': client,
      'case': name,
      'ms': _now() - started,
      ...row,
    };
    results.add(result);
    _drawRow(result);
  }
  final failed = results.where((r) => r['ok'] != true).length;
  _drawSummary(failed);
  web.window.setProperty('fetchResult'.toJS, jsonEncode(results).toJS);
  web.window.setProperty('fetchDone'.toJS, true.toJS);
}

/// What one case may take.
const _caseTimeout = Duration(seconds: 20);

web.HTMLTableSectionElement? _tbody;
web.HTMLElement? _summaryLine;

/// The page: a table of the cases and a last line, for a hand-held run.
void _draw() {
  final body = web.document.body!;
  body.style
    ..fontFamily = 'sans-serif'
    ..margin = '12px';
  final title = web.document.createElement('h1') as web.HTMLElement
    ..textContent = 'fespalier_dio fetch adapter';
  title.style.fontSize = '1.2em';
  _summaryLine = web.document.createElement('p') as web.HTMLElement
    ..id = 'summary'
    ..textContent = 'running ...';
  final table = web.document.createElement('table') as web.HTMLTableElement;
  table.style
    ..borderCollapse = 'collapse'
    ..fontSize = '0.8em';
  _tbody = web.document.createElement('tbody') as web.HTMLTableSectionElement;
  table.appendChild(_tbody!);
  body
    ..appendChild(title)
    ..appendChild(_summaryLine!)
    ..appendChild(table);
}

void _drawRow(Map<String, Object?> row) {
  final ok = row['ok'] == true;
  final detail = ok
      ? jsonEncode({
          for (final e in row.entries)
            if (!const {'client', 'case', 'ms', 'ok'}.contains(e.key))
              e.key: e.value,
        })
      : '${row['error']}';
  final tr = web.document.createElement('tr') as web.HTMLElement;
  tr.style.color = ok ? 'green' : 'red';
  for (final text in [
    ok ? 'ok' : 'FAIL',
    '${row['client']}',
    '${row['case']}',
    '${row['ms']} ms',
    detail,
  ]) {
    final td = web.document.createElement('td') as web.HTMLElement
      ..textContent = text;
    td.style
      ..padding = '2px 6px'
      ..border = '1px solid #ccc'
      ..wordBreak = 'break-word';
    tr.appendChild(td);
  }
  _tbody?.appendChild(tr);
}

void _drawSummary(int failed) {
  _summaryLine
    ?..textContent = failed == 0 ? 'all passed' : '$failed failed'
    ..style.fontWeight = 'bold'
    ..style.color = failed == 0 ? 'green' : 'red';
}
