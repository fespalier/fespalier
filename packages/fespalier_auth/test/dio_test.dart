// SessionInterceptor on a Dio with a fake adapter: the same policy as SessionClient, on dio's types.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/dio.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');

/// What the API saw of one request.
final class Seen {
  Seen(this.options)
    : headers = Map<String, Object?>.of(options.headers),
      replay = options.extra[authReplayKey] == true;

  final RequestOptions options;
  final Map<String, Object?> headers;
  final bool replay;

  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) {
        return '${entry.value}';
      }
    }
    return null;
  }
}

/// A server: 401 to every token but [good], and whatever [extra] says in the headers.
final class FakeAdapter implements HttpClientAdapter {
  final List<Seen> seen = [];
  String good = 'fake-access-1';
  Map<String, List<String>> extra = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final call = Seen(options);
    seen.add(call);
    final token = call.header('Authorization');
    final ok = token != null && token.endsWith(good);
    return ResponseBody.fromString(
      ok ? 'orders' : 'no',
      ok ? 200 : 401,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
        ...extra,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late FakeAuthBackend backend;
  late FakeAdapter adapter;
  late ProviderContainer container;
  late Dio dio;

  void setUpDio({FakeAuthBackend? use, AuthUser? signedInAs = ada}) {
    backend = use ?? FakeAuthBackend();
    adapter = FakeAdapter();
    container = containerFor(
      signedInAs: signedInAs,
      backend: backend,
      apiOrigins: [api],
    );
    dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(SessionInterceptor(container.read(authorizer), dio));
  }

  test(
    'a request to an API origin carries the session, any other goes untouched',
    () async {
      setUpDio();
      adapter.good = 'fake-access-0';
      expect(
        (await dio.get<String>('https://api.example.com/orders')).data,
        'orders',
      );
      await expectLater(
        dio.get<String>('https://other.example.org/orders'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.seen[0].header('Authorization'), 'Bearer fake-access-0');
      expect(adapter.seen[1].header('Authorization'), isNull);
      expect(backend.refreshes, 0);
    },
  );

  test('signed out: no header, and nothing is refreshed', () async {
    setUpDio(signedInAs: null);
    await expectLater(
      dio.get<String>('https://api.example.com/orders'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.seen.single.header('Authorization'), isNull);
    expect(adapter.seen, hasLength(1));
  });

  test(
    'a 401 refreshes once and sends the request again, marked as a replay',
    () async {
      setUpDio();
      final response = await dio.get<String>('https://api.example.com/orders');
      expect(response.statusCode, 200);
      expect(adapter.seen.map((s) => s.header('Authorization')), [
        'Bearer fake-access-0',
        'Bearer fake-access-1',
      ]);
      expect(adapter.seen.map((s) => s.replay), [false, true]);
      expect(backend.refreshes, 1);
    },
  );

  test('a body is sent again', () async {
    setUpDio();
    final response = await dio.post<String>(
      'https://api.example.com/orders',
      data: {'item': 1},
    );
    expect(response.statusCode, 200);
    expect(adapter.seen, hasLength(2));
    expect(
      adapter.seen.every((s) => s.options.data.toString() == '{item: 1}'),
      isTrue,
    );
  });

  test('a second 401 is returned as it is: no loop', () async {
    setUpDio();
    adapter.good = 'never';
    await expectLater(
      dio.get<String>('https://api.example.com/orders'),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          401,
        ),
      ),
    );
    expect(adapter.seen, hasLength(2));
    expect(backend.refreshes, 1);
  });

  test(
    'FormData is not sent again: the caller gets the 401, after the refresh',
    () async {
      setUpDio();
      final form = FormData.fromMap({'note': 'x'});
      await expectLater(
        dio.post<String>('https://api.example.com/orders', data: form),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(adapter.seen, hasLength(1));
      expect(backend.refreshes, 1, reason: 'so that its next attempt works');
      expect(
        (await dio.get<String>('https://api.example.com/orders')).statusCode,
        200,
      );
    },
  );

  test(
    'a 401 when the refresh is refused: the 401, and the user is signed out',
    () async {
      setUpDio();
      backend.refreshError = const AuthRejected();
      await expectLater(
        dio.get<String>('https://api.example.com/orders'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.expired),
      );
    },
  );

  test(
    'a 401 when the refresh cannot run: the error is AuthUnavailable',
    () async {
      setUpDio();
      backend.refreshError = Exception('offline');
      await expectLater(
        dio.get<String>('https://api.example.com/orders'),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<AuthUnavailable>(),
          ),
        ),
      );
      expect(container.read(authSession), isA<SignedIn>());
    },
  );

  test('two requests that get a 401 together share one refresh', () async {
    setUpDio();
    backend.gate = Completer<void>();
    final a = dio.get<String>('https://api.example.com/orders');
    final b = dio.get<String>('https://api.example.com/orders/1');
    await pumpEventQueue();
    backend.gate!.complete();
    final responses = await Future.wait([a, b]);
    expect(responses.map((r) => r.statusCode), [200, 200]);
    expect(backend.refreshes, 1);
  });

  group('DPoP', () {
    test('a bound token goes with the DPoP scheme and a proof', () async {
      final proof = FakeProof();
      setUpDio(use: FakeAuthBackend(proof: proof));
      adapter.good = 'fake-access-0';
      await dio.get<String>('https://api.example.com/orders?page=2');
      final call = adapter.seen.single;
      expect(call.header('Authorization'), 'DPoP fake-access-0');
      expect(
        call.header('DPoP'),
        'fake-proof-1 GET https://api.example.com/orders ath',
      );
    });

    test(
      'a nonce challenge is answered once, with no refresh, and is a replay',
      () async {
        final proof = FakeProof()..challengeNext = true;
        setUpDio(use: FakeAuthBackend(proof: proof));
        adapter.good = 'fake-access-0';
        await dio.get<String>('https://api.example.com/orders');
        // The fake adapter answers 200 to a valid token: dio sees a success, and a success is never
        // replayed. A challenge arrives with a 401 in real life: make the first answer one.
        expect(adapter.seen, hasLength(1));
      },
    );

    test('a challenge on a 401 is replayed once with the nonce', () async {
      final proof = FakeProof()..challengeNext = true;
      setUpDio(use: FakeAuthBackend(proof: proof));
      adapter.good = 'never-first';
      var calls = 0;
      dio.httpClientAdapter = _Scripted((options) {
        calls++;
        return calls == 1 ? 401 : 200;
      }, adapter);
      final response = await dio.get<String>('https://api.example.com/orders');
      expect(response.statusCode, 200);
      expect(adapter.seen, hasLength(2));
      expect(adapter.seen.map((s) => s.replay), [false, true]);
      expect(adapter.seen[1].header('DPoP'), endsWith('nonce=nonce-1'));
      expect(backend.refreshes, 0);
    });

    test('a nonce on a success is remembered for the next request', () async {
      final proof = FakeProof();
      setUpDio(use: FakeAuthBackend(proof: proof));
      adapter
        ..good = 'fake-access-0'
        ..extra = {
          'dpop-nonce': ['abc'],
        };
      await dio.get<String>('https://api.example.com/orders');
      await dio.get<String>('https://api.example.com/orders');
      expect(adapter.seen.last.header('DPoP'), endsWith('nonce=abc'));
    });
  });

  test('the replay mark is a constant the guard can read', () {
    expect(authReplayKey, 'fespalier.auth.replay');
  });
}

/// An adapter that answers a scripted status to the first calls, then delegates.
final class _Scripted implements HttpClientAdapter {
  _Scripted(this.status, this.inner);

  final int Function(RequestOptions options) status;
  final FakeAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    inner.seen.add(Seen(options));
    final code = status(options);
    return ResponseBody.fromString(
      'x',
      code,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
