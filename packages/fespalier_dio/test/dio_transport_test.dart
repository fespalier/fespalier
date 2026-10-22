// DioTransport: a Dio as an HttpTransport. Plain test(), not testWidgets: Dio starts its
// interceptor chain with Timer.run, which only a real event loop runs.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final url = Uri.parse('https://api.example.com/items');

TransportRequest get([Uri? uri, Map<String, String>? headers]) =>
    TransportRequest(method: 'GET', uri: uri ?? url, headers: headers ?? {});

TransportRequest write(
  String method,
  String body, {
  Map<String, String> headers = const {},
}) => TransportRequest(
  method: method,
  uri: url,
  headers: headers,
  body: Uint8List.fromList(utf8.encode(body)),
);

DioException dioFailure(RequestOptions options, DioExceptionType type) =>
    DioException(requestOptions: options, type: type);

Future<Object> thrownBy(Future<Object?> future) async {
  try {
    await future;
  } on Object catch (error) {
    return error;
  }
  fail('should throw');
}

void main() {
  test('a non-2xx answer comes back as a response, not an exception', () async {
    final adapter = FakeAdapter(
      (options, _) async => jsonAnswer({'error': 'nope'}, 404),
    );
    final transport = DioTransport(dioOver(adapter));
    final response = await transport.send(get());
    expect(response.statusCode, 404);
    expect(jsonDecode(utf8.decode(await response.bytes())), {'error': 'nope'});
    expect(response.headers['content-type'], contains('application/json'));
  });

  test('response headers are lower-cased and repeated ones joined', () async {
    final adapter = FakeAdapter(
      (options, _) async => ResponseBody.fromString(
        '',
        200,
        headers: {
          'X-Thing': ['a', 'b'],
          'Content-Range': ['bytes 4-7/8'],
        },
        statusMessage: 'Fine',
      ),
    );
    final response = await DioTransport(dioOver(adapter)).send(get());
    expect(response.headers['x-thing'], 'a, b');
    expect(response.headers['content-range'], 'bytes 4-7/8');
    expect(response.reasonPhrase, 'Fine');
  });

  test('the body streams, chunk by chunk', () async {
    final adapter = FakeAdapter((options, _) async {
      final chunks = Stream<Uint8List>.fromIterable([
        Uint8List.fromList(utf8.encode('one,')),
        Uint8List.fromList(utf8.encode('two,')),
        Uint8List.fromList(utf8.encode('three')),
      ]);
      return ResponseBody(chunks, 200);
    });
    final response = await DioTransport(dioOver(adapter)).send(get());
    expect(response.statusCode, 200);
    expect(response.isBuffered, isFalse);
    final seen = await response.body.toList();
    expect(seen, hasLength(3));
    expect(utf8.decode(seen.expand((c) => c).toList()), 'one,two,three');
  });

  test('method, headers and body reach the adapter', () async {
    final adapter = FakeAdapter((options, _) async => emptyAnswer(201));
    final response = await DioTransport(
      dioOver(adapter),
    ).send(write('POST', 'hello', headers: {'x-a': 'b'}));
    expect(response.statusCode, 201);
    final options = adapter.requests.single;
    expect(options.method, 'POST');
    expect(options.uri, url);
    expect(options.headers['x-a'], 'b');
    expect(adapter.bodies.single, utf8.encode('hello'));
  });

  test('a Range header passes through, and a 206 is the answer', () async {
    final adapter = FakeAdapter(
      (options, _) async => ResponseBody.fromString('tial', 206),
    );
    final response = await DioTransport(
      dioOver(adapter),
    ).send(get(null, {'Range': 'bytes=4-'}));
    expect(adapter.requests.single.headers['Range'], 'bytes=4-');
    expect(response.statusCode, 206);
    expect(utf8.decode(await response.bytes()), 'tial');
  });

  group('a body and a session that sends the request again', () {
    // What a session does after a 401 and a refresh: the same RequestOptions go through the Dio
    // once more, marked as the replay.
    Dio replayingDio(FakeAdapter adapter) {
      final dio = dioOver(adapter);
      dio.interceptors.add(_ReplayOn401(dio));
      return dio;
    }

    test('a POST with a body is sent again whole after a 401', () async {
      final adapter = FakeAdapter.sequence([
        () => emptyAnswer(401),
        () => ResponseBody.fromString('ok', 200),
      ]);
      final response = await DioTransport(
        replayingDio(adapter),
      ).send(write('POST', 'hello'));
      expect(response.statusCode, 200);
      expect(utf8.decode(await response.bytes()), 'ok');
      expect(adapter.sent, 2);
      expect(adapter.bodies, [utf8.encode('hello'), utf8.encode('hello')]);
    });

    test('bytes reach Dio as bytes, a stream as a stream', () async {
      final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
      final transport = DioTransport(dioOver(adapter));
      await transport.send(write('POST', 'plain'));
      await transport.send(
        TransportRequest(
          method: 'POST',
          uri: url,
          bodyStream: Stream<List<int>>.value(utf8.encode('streamed')),
          contentLength: 8,
        ),
      );
      expect(adapter.requests[0].data, isA<Uint8List>());
      expect(adapter.requests[1].data, isA<Stream<Uint8List>>());
      expect(adapter.bodies, [utf8.encode('plain'), utf8.encode('streamed')]);
      expect(adapter.requests[1].headers['content-length'], '8');
    });

    test('Content-Length is the length of the bytes', () async {
      final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
      await DioTransport(dioOver(adapter)).send(write('POST', 'héllo'));
      expect(adapter.requests.single.headers['content-length'], '6');
    });

    test('a request without a body sends none', () async {
      final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
      await DioTransport(dioOver(adapter)).send(get());
      expect(adapter.requests.single.data, isNull);
      expect(adapter.bodies.single, isEmpty);
    });

    test('a write whose 401 is replayed is sent twice, and no more', () async {
      final adapter = FakeAdapter((options, _) async => emptyAnswer(401));
      final dio = replayingDio(adapter);
      WriteGuard.install(dio);
      final response = await DioTransport(dio).send(write('PUT', 'x'));
      // The replay is the documented exception to "a write is never sent again": the server
      // refused the first send before running it. The second 401 is the answer.
      expect(response.statusCode, 401);
      expect(adapter.sent, 2);
      expect(adapter.bodies, [utf8.encode('x'), utf8.encode('x')]);
    });

    test(
      'a write that fails after a 401 replay is not sent a third time',
      () async {
        final adapter = FakeAdapter((options, _) async {
          if (options.extra['replayed'] == true) {
            throw dioFailure(options, DioExceptionType.connectionError);
          }
          return emptyAnswer(401);
        });
        final dio = replayingDio(adapter);
        dio.interceptors.add(
          RetryInterceptor(
            dio: dio,
            retries: 3,
            retryDelays: const [Duration.zero],
          ),
        );
        WriteGuard.install(dio);
        await expectLater(
          DioTransport(dio).send(write('POST', 'x')),
          throwsA(isA<TransportUnsent>()),
        );
        expect(adapter.sent, 2);
      },
    );
  });

  test('the Dio interceptors run on the way out', () async {
    final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
    final dio = dioOver(adapter);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['authorization'] = 'Bearer from-interceptor';
          handler.next(options);
        },
      ),
    );
    await DioTransport(dio).send(get());
    expect(
      adapter.requests.single.headers['authorization'],
      'Bearer from-interceptor',
    );
  });

  test('attributes reach Options.extra and are never sent', () async {
    final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
    await DioTransport(dioOver(adapter)).send(
      TransportRequest(
        method: 'GET',
        uri: url,
        attributes: const {transportReplayKey: true, 'app.role': 'admin'},
      ),
    );
    final options = adapter.requests.single;
    expect(options.extra[transportReplayKey], true);
    expect(options.extra['app.role'], 'admin');
    expect(options.headers.keys, isNot(contains(transportReplayKey)));
    expect(options.headers.keys, isNot(contains('app.role')));
  });

  test(
    'WriteGuard runs: a write a retrier would send again is sent once',
    () async {
      final adapter = FakeAdapter(
        (options, _) async =>
            throw dioFailure(options, DioExceptionType.connectionError),
      );
      final dio = dioOver(adapter);
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero],
        ),
      );
      WriteGuard.install(dio);
      final transport = DioTransport(dio);
      await expectLater(
        transport.send(write('PUT', 'x')),
        throwsA(isA<TransportUnsent>()),
      );
      expect(adapter.sent, 1, reason: 'a write is never retried');
      // A read goes round again.
      adapter.requests.clear();
      await expectLater(transport.send(get()), throwsA(isA<TransportUnsent>()));
      expect(adapter.sent, greaterThan(1));
    },
  );

  group('failures', () {
    Future<Object> failWith(
      DioExceptionType type, {
      Object? error,
      StackTrace? stackTrace,
    }) {
      final adapter = FakeAdapter(
        (options, _) async => throw DioException(
          requestOptions: options,
          type: type,
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return thrownBy(DioTransport(dioOver(adapter)).send(get()));
    }

    test('each Dio type maps to one transport failure', () async {
      final expected = <DioExceptionType, Matcher>{
        DioExceptionType.cancel: isA<TransportAborted>(),
        DioExceptionType.connectionError: isA<TransportUnsent>(),
        DioExceptionType.connectionTimeout: isA<TransportUnsent>(),
        DioExceptionType.badCertificate: isA<TransportUntrusted>(),
        DioExceptionType.sendTimeout: isA<TransportTimedOut>(),
        DioExceptionType.receiveTimeout: isA<TransportTimedOut>(),
        DioExceptionType.badResponse: isA<TransportBroken>(),
        DioExceptionType.unknown: isA<TransportBroken>(),
      };
      for (final entry in expected.entries) {
        expect(await failWith(entry.key), entry.value, reason: '${entry.key}');
      }
    });

    test('the failure keeps Dio\'s error as its cause and the URL', () async {
      final failure =
          await failWith(DioExceptionType.connectionTimeout)
              as TransportFailure;
      expect(failure.cause, isA<DioException>());
      expect(failure.uri, url);
    });

    test('the text of a failure never names the server', () async {
      final failure = await failWith(
        DioExceptionType.connectionError,
        error: Exception('connect to api.example.com failed'),
      );
      expect('$failure', isNot(contains('example.com')));
      expect('$failure', isNot(contains('https')));
    });

    test('a thing that is not an Exception is a broken exchange', () async {
      final adapter = FakeAdapter(
        (options, _) async => throw StateError('boom'),
      );
      final failure =
          await thrownBy(DioTransport(dioOver(adapter)).send(get()))
              as TransportBroken;
      expect((failure.cause! as DioException).error, isA<StateError>());
    });

    test('a TransportFailure in error is the failure thrown', () async {
      const inner = TransportTimedOut();
      final thrown = await failWith(DioExceptionType.unknown, error: inner);
      expect(identical(thrown, inner), isTrue);
    });

    test('an Exception an interceptor rejected with passes through', () async {
      final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
      final dio = dioOver(adapter);
      final rejection = _Rejection('signed out');
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(requestOptions: options, error: rejection),
          ),
        ),
      );
      final thrown = await thrownBy(DioTransport(dio).send(get()));
      expect(identical(thrown, rejection), isTrue);
      expect(adapter.sent, 0);
    });

    test('an Exception of a connection error is not unwrapped', () async {
      final thrown = await failWith(
        DioExceptionType.connectionError,
        error: Exception('socket'),
      );
      expect(thrown, isA<TransportUnsent>());
    });
  });

  group('abort', () {
    test('a trigger that fires cancels the request', () async {
      final sawCancel = Completer<void>();
      final started = Completer<void>();
      final adapter = FakeAdapter((options, cancelFuture) {
        started.complete();
        unawaited(cancelFuture?.then(sawCancel.complete));
        return Completer<ResponseBody>().future;
      });
      final trigger = Completer<void>();
      final pending = DioTransport(dioOver(adapter)).send(
        TransportRequest(method: 'GET', uri: url, abortTrigger: trigger.future),
      );
      final failed = expectLater(pending, throwsA(isA<TransportAborted>()));
      await started.future;
      trigger.complete();
      await failed;
      await sawCancel.future;
    });

    test('a trigger that never fires costs nothing', () async {
      final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
      final response = await DioTransport(dioOver(adapter)).send(
        TransportRequest(
          method: 'GET',
          uri: url,
          abortTrigger: Completer<void>().future,
        ),
      );
      expect(response.statusCode, 200);
    });
  });

  test('the Dio still works after the transport is dropped', () async {
    final adapter = FakeAdapter((options, _) async => emptyAnswer(200));
    final dio = dioOver(adapter);
    DioTransport(dio);
    final res = await dio.get<String>(url.toString());
    expect(res.statusCode, 200);
  });
}

final class _Rejection implements Exception {
  _Rejection(this.reason);

  final String reason;
}

/// Sends a request that got a 401 once more, through the same Dio and with the same
/// `RequestOptions`, as a session does after a refresh.
final class _ReplayOn401 extends Interceptor {
  _ReplayOn401(this.dio);

  final Dio dio;

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final options = response.requestOptions;
    if (response.statusCode != 401 || options.extra['replayed'] == true) {
      return handler.next(response);
    }
    options.extra['replayed'] = true;
    try {
      handler.next(await dio.fetch<dynamic>(options));
    } on DioException catch (error) {
      handler.reject(error);
    }
  }
}
