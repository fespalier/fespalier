// SessionInterceptor on a Dio with a fake adapter: the same policy as SessionClient, on dio's types.
import 'dart:async';
import 'dart:convert';
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

  /// The body of each request, as the adapter read it (a stream can be read once, as it is for a
  /// real adapter).
  final List<List<int>> bodies = [];
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
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
    }
    bodies.add(body);
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

/// A proof that can stop making headers, like a signer that failed.
final class _SwitchableProof implements ProofOfPossession {
  bool on = true;

  @override
  Future<String?> thumbprint() async => 'thumb';

  @override
  Future<Map<String, String>> headers({
    required String method,
    required Uri uri,
    String? accessToken,
  }) async => on ? {'DPoP': 'proof'} : {};

  @override
  bool onResponse({
    required Uri uri,
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  }) => false;

  @override
  Future<void> reset() async {}
}

void main() {
  late FakeAuthBackend backend;
  late FakeAdapter adapter;
  late ProviderContainer container;
  late Dio dio;

  void setUpDio({
    FakeAuthBackend? use,
    AuthUser? signedInAs = ada,
    Duration? tokenLifetime,
  }) {
    backend = use ?? FakeAuthBackend(tokenLifetime: tokenLifetime);
    adapter = FakeAdapter();
    container = containerFor(
      signedInAs: signedInAs,
      backend: backend,
      apiOrigins: [api],
      tokenLifetime: tokenLifetime,
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

  test('a body of bytes is sent again whole', () async {
    setUpDio();
    final response = await dio.post<String>(
      'https://api.example.com/orders',
      data: Uint8List.fromList(utf8.encode('item')),
    );
    expect(response.statusCode, 200);
    expect(adapter.bodies, [utf8.encode('item'), utf8.encode('item')]);
    expect(backend.refreshes, 1);
  });

  group('a body that is a stream', () {
    // What a streamed `package:http` request becomes in `DioHttpClient`: it can be read once.
    Stream<Uint8List> body() =>
        Stream<Uint8List>.value(Uint8List.fromList(utf8.encode('item')));

    test(
      'is not sent again: the caller gets the 401, after the refresh',
      () async {
        setUpDio();
        await expectLater(
          dio.post<String>('https://api.example.com/orders', data: body()),
          throwsA(
            isA<DioException>()
                .having((e) => e.response?.statusCode, 'status', 401)
                .having((e) => e.error, 'no failure of its own', isNull),
          ),
        );
        expect(adapter.seen, hasLength(1));
        expect(adapter.bodies.single, utf8.encode('item'));
        expect(backend.refreshes, 1, reason: 'so that its next attempt works');
        expect(
          (await dio.get<String>('https://api.example.com/orders')).statusCode,
          200,
        );
      },
    );

    test(
      'with a client that takes a 401 as an answer, it is the answer',
      () async {
        setUpDio();
        final response = await dio.post<String>(
          'https://api.example.com/orders',
          data: body(),
          options: Options(validateStatus: (_) => true),
        );
        expect(response.statusCode, 401);
        expect(adapter.seen, hasLength(1));
        expect(backend.refreshes, 1);
      },
    );
  });

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

  // The same RequestOptions fetched twice is what a retrier does (dio_smart_retry calls
  // dio.fetch(requestOptions)): these two pin that the second send is not a fresh request.
  group('a request sent again with the same options', () {
    test('whose refresh was refused is refused again, without a send', () async {
      // Pins (a): the refused mark in options.extra[authRefusedKey]. Without it a sign-in after the
      // refusal lets the next fetch go out as the new user, and, with neither mark, the
      // second fetch finds nobody signed in and goes out with no Authorization.
      setUpDio(tokenLifetime: const Duration(seconds: -1));
      backend.refreshError = const AuthRejected();
      final options = RequestOptions(path: 'https://api.example.com/orders');
      for (var i = 0; i < 2; i++) {
        await expectLater(
          dio.fetch<String>(options),
          throwsA(
            isA<DioException>().having(
              (e) => e.error,
              'error',
              isA<AuthRejected>(),
            ),
          ),
        );
      }
      expect(adapter.seen, isEmpty);
      expect(backend.refreshes, 1);
      expect(options.extra[authRefusedKey], isA<AuthRejected>());
      // Signing in again does not undo it for this request: it stays refused, and is not sent as
      // whoever signed in since (no earlier attempt carried a user to compare with).
      backend
        ..refreshError = null
        ..tokenLifetime = null;
      await container
          .read(authSession.notifier)
          .signIn(const PasswordSignIn(username: 'ada', password: 'ada'));
      adapter.good = 'fake-access-1';
      await expectLater(
        dio.fetch<String>(options),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<AuthRejected>(),
          ),
        ),
      );
      expect(adapter.seen, isEmpty);
    });

    test('is not sent without the session it had (a sign-out)', () async {
      // Pins (b): a request that had the session is not sent without it.
      setUpDio();
      adapter.good = 'fake-access-0';
      final options = RequestOptions(path: 'https://api.example.com/orders');
      expect((await dio.fetch<String>(options)).statusCode, 200);
      await container.read(authSession.notifier).signOut();
      await expectLater(
        dio.fetch<String>(options),
        throwsA(
          isA<DioException>().having(
            (e) => e.error,
            'error',
            isA<AuthRejected>(),
          ),
        ),
      );
      expect(adapter.seen, hasLength(1));
    });

    test('drops the previous send\'s headers', () async {
      // Pins (c): the DPoP header of the first send must not stay when the second attempt has no
      // proof (a proof that could not be made). Without the removal it travels beside the new
      // Authorization.
      final proof = _SwitchableProof();
      // Signed in through the backend: only that makes a DPoP-bound session for this proof.
      setUpDio(use: FakeAuthBackend(proof: proof), signedInAs: null);
      await container
          .read(authSession.notifier)
          .signIn(const PasswordSignIn(username: 'ada', password: 'ada'));
      adapter.good = 'fake-access-1';
      final options = RequestOptions(path: 'https://api.example.com/orders');
      await dio.fetch<String>(options);
      proof.on = false;
      await dio.fetch<String>(options);
      expect(adapter.seen[0].header('DPoP'), 'proof');
      expect(adapter.seen[1].header('Authorization'), 'DPoP fake-access-1');
      expect(adapter.seen[1].header('DPoP'), isNull);
    });

    test(
      'is not sent as another user (a sign-out, then bob signs in)',
      () async {
        // Pins (d): the attempt remembers its user.
        setUpDio();
        final options = RequestOptions(path: 'https://api.example.com/orders');
        adapter.good = 'fake-access-0';
        await dio.fetch<String>(options);
        final notifier = container.read(authSession.notifier);
        await notifier.signOut();
        backend.user = bob;
        await notifier.signIn(
          const PasswordSignIn(username: 'bob', password: 'bob'),
        );
        adapter.good = 'fake-access-1';
        await expectLater(
          dio.fetch<String>(options),
          throwsA(
            isA<DioException>().having(
              (e) => e.error,
              'error',
              isA<AuthRejected>(),
            ),
          ),
        );
        expect(adapter.seen, hasLength(1));
      },
    );

    test(
      'after AuthUnavailable is not marked refused: the next send may work',
      () async {
        setUpDio(tokenLifetime: const Duration(seconds: -1));
        backend.refreshError = AuthUnavailable(StateError('offline'));
        final options = RequestOptions(path: 'https://api.example.com/orders');
        await expectLater(
          dio.fetch<String>(options),
          throwsA(isA<DioException>()),
        );
        expect(options.extra[authRefusedKey], isNull);
        expect(options.extra[authWantedKey], isTrue);
        backend.refreshError = null;
        adapter.good = 'fake-access-1';
        expect((await dio.fetch<String>(options)).statusCode, 200);
      },
    );
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
