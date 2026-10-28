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
// and, for the fetch adapter alone: cancelling the body subscription, Dio's CancelToken (after
// and before the headers) and `close(force: true)` abort the request; a port nothing listens on
// is a connection error (`TransportUnsent` through DioTransport); a POST body arrives whole; and
// `withCredentials` (and `Options.extra['withCredentials']`) choose the request's credentials.
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
import 'package:fespalier_stream/src/wire/event_source.dart';
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
  final subscription = source.events.listen((_) {
    if (++seen == 3 && !three.isCompleted) three.complete();
  });
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
  var events = 0;
  final three = Completer<void>();
  final subscription = body.stream.listen((chunk) {
    events += utf8
        .decode(chunk)
        .split('\n\n')
        .where((b) => b.startsWith('id:'))
        .length;
    if (events >= 3 && !three.isCompleted) three.complete();
  });
  await three.future;
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
  var events = 0;
  final three = Completer<void>();
  Object? error;
  final done = Completer<void>();
  response.data!.stream.listen(
    (chunk) {
      events += utf8
          .decode(chunk)
          .split('\n\n')
          .where((b) => b.startsWith('id:'))
          .length;
      if (events >= 3 && !three.isCompleted) three.complete();
    },
    onError: (Object e) => error = e,
    onDone: done.complete,
  );
  await three.future;
  token.cancel('enough');
  final log = await _serverSaw(id, 'closed');
  _expect(log.contains('closed $id after 3'), 'the server saw $log');
  await done.future.then((_) {}, onError: (Object _) {});
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
  final three = Completer<void>();
  final ended = Completer<Object?>();
  var events = 0;
  body.stream.listen(
    (chunk) {
      events += utf8
          .decode(chunk)
          .split('\n\n')
          .where((b) => b.startsWith('id:'))
          .length;
      if (events >= 3 && !three.isCompleted) three.complete();
    },
    onError: (Object e) {
      if (!ended.isCompleted) ended.complete(e);
    },
    onDone: () {
      if (!ended.isCompleted) ended.complete(null);
    },
  );
  await three.future;
  adapter.close(force: true);
  final error = await ended.future;
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
    ('dio', 'credentials', _credentials),
  ];
  final results = <Map<String, Object?>>[];
  for (final (client, name, run) in cases) {
    final started = _now();
    Map<String, Object?> row;
    try {
      row = {'ok': true, ...await run()};
    } on Object catch (error) {
      row = {'ok': false, 'error': '$error'};
    }
    results.add({
      'client': client,
      'case': name,
      'ms': _now() - started,
      ...row,
    });
  }
  web.window.setProperty('fetchResult'.toJS, jsonEncode(results).toJS);
  web.window.setProperty('fetchDone'.toJS, true.toJS);
}
