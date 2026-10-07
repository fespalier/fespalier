// WriteGuard: a write is never sent twice, whatever retries it. Run against the retry interceptor
// apps actually use (dio_smart_retry, with no delay) and a fake auth interceptor that sends again
// after a 401, the way fespalier_auth's does. Plain test(): Dio starts its chain with Timer.run.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const hint =
    'fespalier_dio: PUT /me failed and was about to be sent again. A write is never retried, so '
    'its first error is returned. Give the retry interceptor WriteGuard.readsOnly(...) as its '
    'evaluator, or add an Idempotency-Key header to a write that is safe to repeat.';

const notRetried =
    'WriteNotRetried: PUT /me was sent again by an interceptor that runs before WriteGuard, so '
    'the error of its first send is unknown. A write is never retried. Call '
    'WriteGuard.install(dio) after adding every other interceptor: it puts WriteGuard first.';

/// A Dio over [adapter] with the retry interceptor and the guard, the order docs/http.md gives.
Dio retrying(
  FakeAdapter adapter, {
  FutureOr<bool> Function(DioException error, int attempt)? evaluator,
  bool guard = true,
}) {
  final dio = dioOver(adapter);
  dio.interceptors.add(
    RetryInterceptor(
      dio: dio,
      retries: 3,
      retryDelays: const [Duration.zero],
      retryEvaluator: evaluator,
    ),
  );
  if (guard) WriteGuard.install(dio);
  return dio;
}

ResponseBody Function() status(int code) =>
    () => jsonAnswer({'status': code}, code);

Future<DioException> failure(Future<Object?> future) async {
  try {
    await future;
  } on DioException catch (error) {
    return error;
  }
  fail('the request should have failed');
}

/// An interceptor that sends a failed request again once after a 401, like a token refresh.
final class FakeRefresh extends Interceptor {
  FakeRefresh(this.dio);

  final Dio dio;
  int replays = 0;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.response?.statusCode != 401 ||
        err.requestOptions.extra['replayed'] == true) {
      return handler.next(err);
    }
    err.requestOptions.extra['replayed'] = true;
    replays++;
    try {
      handler.resolve(await dio.fetch<Object?>(err.requestOptions));
    } on DioException catch (error) {
      handler.reject(error);
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    if (response.statusCode != 401 ||
        response.requestOptions.extra['replayed'] == true) {
      return handler.next(response);
    }
    response.requestOptions.extra['replayed'] = true;
    replays++;
    try {
      handler.resolve(await dio.fetch<Object?>(response.requestOptions));
    } on DioException catch (error) {
      handler.reject(error);
    }
  }
}

/// An interceptor that sends every failed request again at once: a retrier that is placed wrongly.
final class Resend extends Interceptor {
  Resend(this.dio);

  final Dio dio;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    try {
      handler.resolve(await dio.fetch<Object?>(err.requestOptions));
    } on DioException catch (error) {
      handler.reject(error);
    }
  }
}

void main() {
  group('a write that fails', () {
    test(
      'is sent once, and the caller gets the first error (and a debug build says why)',
      () async {
        final adapter = FakeAdapter.sequence([status(503), status(200)]);
        final dio = retrying(adapter);
        late DioException error;
        final printed = await printedDuring(() async {
          error = await failure(
            dio.put<Object?>('https://api.example.com/me', data: {'a': 1}),
          );
        });

        expect(adapter.sent, 1);
        expect(error.response?.statusCode, 503);
        expect(printed, [hint]);
      },
    );

    test('says it once for each request that was refused', () async {
      final adapter = FakeAdapter.sequence([status(503)]);
      final dio = retrying(adapter);
      final printed = await printedDuring(() async {
        await failure(dio.put<Object?>('https://api.example.com/me'));
        await failure(dio.put<Object?>('https://api.example.com/me'));
      });

      expect(adapter.sent, 2); // one send per request
      expect(printed, [hint, hint]); // and one line per request
    });

    test(
      'with readsOnly the retrier is not even asked, and nothing is printed',
      () async {
        final asked = <String>[];
        final adapter = FakeAdapter.sequence([status(503), status(200)]);
        final dio = retrying(
          adapter,
          evaluator: WriteGuard.readsOnly((error, attempt) {
            asked.add(error.requestOptions.method);
            return DefaultRetryEvaluator(
              defaultRetryableStatuses,
            ).evaluate(error, attempt);
          }),
        );
        late DioException error;
        final printed = await printedDuring(() async {
          error = await failure(
            dio.post<Object?>('https://api.example.com/orders'),
          );
        });

        expect(adapter.sent, 1);
        expect(error.response?.statusCode, 503);
        expect(asked, isEmpty);
        expect(printed, isEmpty);
      },
    );

    test(
      'names only the method and the path, never the host, the query or the body',
      () async {
        final adapter = FakeAdapter.sequence([status(503)]);
        final dio = retrying(adapter);
        final printed = await printedDuring(() async {
          await failure(
            dio.put<Object?>(
              'https://secret-host.example.com/me?token=abc',
              data: {'password': 'hunter2'},
            ),
          );
        });

        expect(printed.single, hint);
        expect(printed.single, isNot(contains('secret-host')));
        expect(printed.single, isNot(contains('abc')));
        expect(printed.single, isNot(contains('hunter2')));
      },
    );
  });

  group('what is not a write', () {
    test('a GET is retried', () async {
      final adapter = FakeAdapter.sequence([status(503), status(200)]);
      final dio = retrying(adapter);
      final response = await dio.get<Object?>('https://api.example.com/items');

      expect(adapter.sent, 2);
      expect(response.statusCode, 200);
    });

    test('a GET is asked to readsOnly, and retried when it says so', () async {
      final asked = <String>[];
      final adapter = FakeAdapter.sequence([status(503), status(200)]);
      final dio = retrying(
        adapter,
        evaluator: WriteGuard.readsOnly((error, attempt) {
          asked.add(error.requestOptions.method);
          return true;
        }),
      );
      final response = await dio.get<Object?>('https://api.example.com/items');

      expect(asked, ['GET']);
      expect(adapter.sent, 2);
      expect(response.statusCode, 200);
    });

    test(
      'a write with an Idempotency-Key header is retried, in any case of the name',
      () async {
        for (final name in [
          'Idempotency-Key',
          'idempotency-key',
          'IDEMPOTENCY-KEY',
        ]) {
          final adapter = FakeAdapter.sequence([status(503), status(200)]);
          final dio = retrying(adapter);
          final response = await dio.post<Object?>(
            'https://api.example.com/orders',
            options: Options(headers: {name: 'k-1'}),
          );

          expect(adapter.sent, 2, reason: name);
          expect(response.statusCode, 200);
        }
      },
    );

    test(
      'a write marked with extra[WriteGuard.idempotent] is retried',
      () async {
        final adapter = FakeAdapter.sequence([status(503), status(200)]);
        final dio = retrying(adapter);
        final response = await dio.put<Object?>(
          'https://api.example.com/me',
          options: Options(extra: {WriteGuard.idempotent: true}),
        );

        expect(adapter.sent, 2);
        expect(response.statusCode, 200);
      },
    );

    test('extra[WriteGuard.write] makes a GET a write', () async {
      final adapter = FakeAdapter.sequence([status(503), status(200)]);
      final dio = retrying(adapter);
      late DioException error;
      final printed = await printedDuring(() async {
        error = await failure(
          dio.get<Object?>(
            'https://api.example.com/export',
            options: Options(extra: {WriteGuard.write: true}),
          ),
        );
      });

      expect(adapter.sent, 1);
      expect(error.response?.statusCode, 503);
      expect(printed.single, contains('GET /export failed'));
    });

    test('isWrite: every method, the header and the two keys', () {
      bool isWrite(
        String method, {
        Map<String, Object?>? headers,
        Map<String, Object?>? extra,
      }) => WriteGuard.isWrite(
        RequestOptions(
          path: '/x',
          method: method,
          headers: headers,
          extra: extra,
        ),
      );

      for (final method in ['GET', 'get', 'HEAD', 'OPTIONS', 'TRACE']) {
        expect(isWrite(method), isFalse, reason: method);
      }
      for (final method in ['POST', 'put', 'PATCH', 'DELETE', 'PROPFIND']) {
        expect(isWrite(method), isTrue, reason: method);
      }
      expect(isWrite('POST', headers: {'idempotency-key': 'k'}), isFalse);
      expect(isWrite('POST', extra: {WriteGuard.idempotent: true}), isFalse);
      expect(isWrite('POST', extra: {WriteGuard.idempotent: false}), isTrue);
      expect(isWrite('GET', extra: {WriteGuard.write: true}), isTrue);
      expect(
        isWrite(
          'GET',
          extra: {WriteGuard.write: true, WriteGuard.idempotent: true},
        ),
        isFalse,
      );
      expect(WriteGuard.idempotent, 'fespalier.idempotent');
      expect(WriteGuard.write, 'fespalier.write');
    });
  });

  group('a retrier that runs before the guard', () {
    test('gets WriteNotRetried: the first error is not known yet', () async {
      final adapter = FakeAdapter.sequence([status(503), status(200)]);
      final dio = dioOver(adapter);
      // Not install(): the resending interceptor is first, so it sees the error before the guard.
      dio.interceptors
        ..add(Resend(dio))
        ..add(const WriteGuard());
      final error = await failure(
        dio.put<Object?>('https://api.example.com/me'),
      );

      expect(adapter.sent, 1);
      expect(error.error, isA<WriteNotRetried>());
      expect('${error.error}', notRetried);
      expect((error.error! as WriteNotRetried).method, 'PUT');
      expect((error.error! as WriteNotRetried).path, '/me');
    });

    test(
      'install puts the guard first, and then the same retrier is stopped',
      () async {
        final adapter = FakeAdapter.sequence([status(503), status(200)]);
        final dio = dioOver(adapter);
        dio.interceptors.add(Resend(dio));
        WriteGuard.install(dio);
        late DioException error;
        final printed = await printedDuring(() async {
          error = await failure(dio.put<Object?>('https://api.example.com/me'));
        });

        expect(adapter.sent, 1);
        expect(error.response?.statusCode, 503);
        expect(printed, [hint]);
      },
    );
  });

  group('a write that is sent again after a 401 (an auth refresh)', () {
    test(
      'is allowed once, and the answer of the second send is the result',
      () async {
        final adapter = FakeAdapter.sequence([status(401), status(200)]);
        final dio = dioOver(adapter);
        final refresh = FakeRefresh(dio);
        dio.interceptors.add(refresh);
        WriteGuard.install(dio);
        final response = await dio.put<Object?>('https://api.example.com/me');

        expect(adapter.sent, 2);
        expect(refresh.replays, 1);
        expect(response.statusCode, 200);
      },
    );

    test('a second 401 is the caller\'s: the refresh replays once', () async {
      final adapter = FakeAdapter.sequence([status(401)]);
      final dio = dioOver(adapter);
      final refresh = FakeRefresh(dio);
      dio.interceptors.add(refresh);
      WriteGuard.install(dio);
      final error = await failure(
        dio.put<Object?>('https://api.example.com/me'),
      );

      expect(adapter.sent, 2);
      expect(error.response?.statusCode, 401);
    });

    test('and a 503 after the replay is not retried', () async {
      final adapter = FakeAdapter.sequence([
        status(401),
        status(503),
        status(200),
      ]);
      final dio = dioOver(adapter);
      dio.interceptors.add(FakeRefresh(dio));
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retryDelays: const [Duration.zero],
          retryEvaluator: (error, attempt) => true,
        ),
      );
      WriteGuard.install(dio);
      late DioException error;
      final printed = await printedDuring(() async {
        error = await failure(dio.put<Object?>('https://api.example.com/me'));
      });

      expect(adapter.sent, 2);
      expect(error.response?.statusCode, 503);
      expect(printed, [hint]);
    });

    test(
      'a client that accepts a 401 as a response has it replayed too',
      () async {
        final adapter = FakeAdapter.sequence([status(401), status(200)]);
        final dio = dioOver(adapter);
        final refresh = FakeRefresh(dio);
        dio.interceptors.add(refresh);
        WriteGuard.install(dio);
        final response = await dio.put<Object?>(
          'https://api.example.com/me',
          options: Options(validateStatus: (_) => true),
        );

        expect(adapter.sent, 2);
        expect(refresh.replays, 1);
        expect(response.statusCode, 200);
      },
    );

    test('a 401 on a read is no business of the guard', () async {
      final adapter = FakeAdapter.sequence([status(401), status(200)]);
      final dio = dioOver(adapter);
      dio.interceptors.add(FakeRefresh(dio));
      WriteGuard.install(dio);
      final response = await dio.get<Object?>('https://api.example.com/items');

      expect(adapter.sent, 2);
      expect(response.statusCode, 200);
    });
  });

  group('install', () {
    test(
      'puts one guard first, however often it is called and whatever is added',
      () {
        final dio = Dio();
        final first = RetryInterceptor(dio: dio);
        dio.interceptors.add(first);
        WriteGuard.install(dio);
        dio.interceptors.add(LogInterceptor());
        WriteGuard.install(dio);
        WriteGuard.install(dio);

        expect(dio.interceptors.first, isA<WriteGuard>());
        expect(dio.interceptors.whereType<WriteGuard>(), hasLength(1));
        expect(dio.interceptors, contains(first));
        expect(dio.interceptors.whereType<LogInterceptor>(), hasLength(1));
        // The one Dio puts there itself (it implies the content type) is still there, after the guard.
        expect(dio.interceptors.length, 4);
      },
    );
  });

  group('the guard on its own', () {
    test(
      'lets a first send of every kind through and keeps no state on the dio',
      () async {
        final adapter = FakeAdapter.sequence([status(200)]);
        final dio = dioOver(adapter);
        WriteGuard.install(dio);

        for (final call in [
          () => dio.get<Object?>('https://api.example.com/a'),
          () => dio.post<Object?>('https://api.example.com/a'),
          () => dio.delete<Object?>('https://api.example.com/a'),
        ]) {
          expect((await call()).statusCode, 200);
        }
        expect(adapter.sent, 3);
      },
    );

    test(
      'a write that succeeded and is sent again by hand is refused, not repeated',
      () async {
        final adapter = FakeAdapter.sequence([status(200)]);
        final dio = dioOver(adapter);
        WriteGuard.install(dio);
        final response = await dio.post<Object?>(
          'https://api.example.com/orders',
        );

        final error = await failure(
          dio.fetch<Object?>(response.requestOptions),
        );
        expect(adapter.sent, 1);
        expect(error.error, isA<WriteNotRetried>());
      },
    );

    test('WriteNotRetried and the debug line say what to do', () {
      const error = WriteNotRetried('PUT', '/me');
      expect('$error', notRetried);
      expect(error, isA<Exception>());
    });
  });
}
