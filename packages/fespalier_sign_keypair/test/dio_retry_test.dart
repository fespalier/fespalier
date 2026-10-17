// A real DPoP proof (DpopProof over FakeDpopSigner's software P-256 key) under fespalier_auth's
// SessionInterceptor and dio_smart_retry, in both interceptor orders. The adapter plays the API
// and checks every send with verifyDpopProof, the way a resource server does: a proof that does
// not verify fails the test. packages/fespalier_dio/test/session_retry_test.dart proves the
// replay and retry rules with FakeProof; this one proves the nonce, the ath, the DPoP header name
// and the single use of each proof with the real thing. Plain test(): Dio starts its chain with
// Timer.run.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_auth/dio.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
const orders = 'https://api.example.com/orders';
const ada = AuthUser(id: 'ada-id');

const nonceChallenge = {
  'DPoP-Nonce': ['srv-1'],
  'WWW-Authenticate': ['DPoP error="use_dpop_nonce"'],
};

/// One scripted answer; [onSend] runs when the request arrives, before the answer.
final class Step {
  const Step(this.status, {this.headers = const {}, this.onSend});

  final int status;
  final Map<String, List<String>> headers;
  final FutureOr<void> Function()? onSend;
}

/// What the API saw of one send, after it verified the proof.
final class Sent {
  Sent({
    required this.method,
    required this.uri,
    required this.authorization,
    required this.proof,
    required this.claims,
    required this.replay,
  });

  final String method;
  final Uri uri;
  final String authorization;
  final String proof;
  final Map<String, Object?> claims;
  final bool replay;

  String get jti => claims['jti']! as String;
  Object? get ath => claims['ath'];
  Object? get nonce => claims['nonce'];
}

/// A resource server: answers from a queue and verifies the `DPoP` header of every send against
/// the send's method, URL and access token, and against the nonce it last issued.
final class VerifyingAdapter implements HttpClientAdapter {
  VerifyingAdapter(Iterable<Step> steps) : _steps = [...steps];

  final List<Step> _steps;
  final List<Sent> sent = [];

  /// The proofs this server refused, with why; every case expects none.
  final List<String> refused = [];

  /// The nonce the server issued last: the next proof must carry it.
  String? nonce;

  List<String> get jtis => [for (final s in sent) s.jti];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    String? header(String name) {
      for (final e in options.headers.entries) {
        if (e.key.toLowerCase() == name.toLowerCase()) return '${e.value}';
      }
      return null;
    }

    final authorization = header('Authorization');
    final proof = header('DPoP');
    if (authorization == null || proof == null) {
      refused.add(
        'send ${sent.length + 1}: no Authorization or no DPoP header',
      );
      throw StateError(refused.last);
    }
    if (!authorization.startsWith('DPoP ')) {
      refused.add('send ${sent.length + 1}: Authorization is not DPoP');
      throw StateError(refused.last);
    }
    final DecodedDpopProof decoded;
    try {
      decoded = verifyDpopProof(
        proof,
        method: options.method,
        uri: options.uri,
        accessToken: authorization.substring('DPoP '.length),
        nonce: nonce,
      );
    } on DpopProofInvalid catch (error) {
      refused.add('send ${sent.length + 1}: $error');
      rethrow;
    }
    sent.add(
      Sent(
        method: options.method,
        uri: options.uri,
        authorization: authorization,
        proof: proof,
        claims: decoded.claims,
        replay: options.extra[authReplayKey] == true,
      ),
    );
    if (_steps.isEmpty) {
      throw StateError('VerifyingAdapter: send ${sent.length} has no step');
    }
    final step = _steps.removeAt(0);
    await step.onSend?.call();
    final issued = step.headers['DPoP-Nonce'];
    if (issued != null) nonce = issued.single;
    return ResponseBody.fromString(
      step.status < 300 ? 'ok' : 'no',
      step.status,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
        ...step.headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

enum Order { retryFirst, sessionFirst }

/// The stack under test, built in [order], signed in as [ada] with a key-bound session.
final class Rig {
  Rig._(this.backend, this.container, this.adapter, this.dio);

  static Future<Rig> create(Order order, List<Step> steps) async {
    final backend = FakeAuthBackend(
      proof: DpopProof(signer: FakeDpopSigner(), random: CountingRandom()),
    );
    // A signed-in start from fakeAuth would be a Bearer session (it binds only a FakeProof), so
    // sign in through the backend: its tokens are DPoP-bound to the real key.
    final container = ProviderContainer(
      overrides: fakeAuth(backend: backend, apiOrigins: [api]),
    );
    addTearDown(container.dispose);
    await container
        .read(authSession.notifier)
        .signIn(const PasswordSignIn(username: 'ada', password: 'ada'));
    final adapter = VerifyingAdapter(steps);
    addTearDown(() => expect(adapter.refused, isEmpty));
    final dio = Dio()..httpClientAdapter = adapter;
    final retry = RetryInterceptor(
      dio: dio,
      retries: 3,
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      retryEvaluator: DefaultRetryEvaluator(defaultRetryableStatuses).evaluate,
    );
    final session = SessionInterceptor(container.read(authorizer), dio);
    dio.interceptors.addAll(switch (order) {
      Order.retryFirst => [retry, session],
      Order.sessionFirst => [session, retry],
    });
    return Rig._(backend, container, adapter, dio);
  }

  final FakeAuthBackend backend;
  final ProviderContainer container;
  final VerifyingAdapter adapter;
  final Dio dio;

  AuthSessionNotifier get notifier => container.read(authSession.notifier);

  /// Every send carried a proof with a `jti` no other send had.
  void expectDistinctJtis() {
    expect(adapter.jtis.toSet(), hasLength(adapter.jtis.length));
    expect(
      adapter.sent.map((s) => s.proof).toSet(),
      hasLength(adapter.sent.length),
    );
  }
}

Future<DioException> failure(Future<Object?> future) async {
  try {
    await future;
  } on DioException catch (error) {
    return error;
  }
  fail('the request should have failed');
}

void main() {
  for (final order in Order.values) {
    group('with ${order.name}', () {
      test(
        'every retried send carries a proof the server accepts, with a jti never seen before',
        () async {
          final rig = await Rig.create(order, [
            const Step(503),
            const Step(503),
            const Step(200),
          ]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.sent, hasLength(3));
          rig.expectDistinctJtis();
          expect(rig.adapter.sent.map((s) => s.authorization).toSet(), {
            'DPoP fake-access-1',
          });
          expect(rig.adapter.sent.map((s) => s.ath).toSet(), {
            accessTokenHash('fake-access-1'),
          });
          expect(rig.backend.refreshes, 0);
        },
      );

      test(
        "after a 401 the replay's ath is the refreshed token's hash",
        () async {
          final rig = await Rig.create(order, [
            const Step(401),
            const Step(200),
          ]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.sent, hasLength(2));
          expect(rig.adapter.sent[0].ath, accessTokenHash('fake-access-1'));
          expect(rig.adapter.sent[1].ath, accessTokenHash('fake-access-2'));
          expect(rig.adapter.sent[1].authorization, 'DPoP fake-access-2');
          expect(rig.adapter.sent.map((s) => s.replay), [false, true]);
          rig.expectDistinctJtis();
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a nonce challenge: the replayed proof carries the server\'s nonce',
        () async {
          final rig = await Rig.create(order, [
            const Step(401, headers: nonceChallenge),
            const Step(200),
          ]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.sent, hasLength(2));
          expect(rig.adapter.sent[0].claims.containsKey('nonce'), isFalse);
          expect(rig.adapter.sent[1].nonce, 'srv-1');
          // Same token: the challenge is about the proof, not the session.
          expect(rig.adapter.sent.map((s) => s.authorization).toSet(), {
            'DPoP fake-access-1',
          });
          rig.expectDistinctJtis();
          expect(rig.backend.refreshes, 0);
        },
      );

      test('a DPoP-Nonce on a 200 is used by the next request', () async {
        final rig = await Rig.create(order, [
          const Step(
            200,
            headers: {
              'DPoP-Nonce': ['srv-2'],
            },
          ),
          const Step(200),
        ]);
        await rig.dio.get<String>(orders);
        await rig.dio.get<String>(orders);
        expect(rig.adapter.sent[0].claims.containsKey('nonce'), isFalse);
        expect(rig.adapter.sent[1].nonce, 'srv-2');
        rig.expectDistinctJtis();
      });

      test(
        'a sign-out between a 503 and its retry: the retry is not sent',
        () async {
          late final Rig rig;
          rig = await Rig.create(order, [
            Step(503, onSend: () => rig.notifier.signOut()),
            const Step(200),
          ]);
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.error, isA<AuthRejected>());
          expect(rig.adapter.sent, hasLength(1));
        },
      );

      test(
        'a write with an Idempotency-Key retried after a 503 carries a new proof each time',
        () async {
          final rig = await Rig.create(order, [
            const Step(503),
            const Step(200),
          ]);
          final response = await rig.dio.put<String>(
            orders,
            data: 'x',
            options: Options(headers: {'Idempotency-Key': 'k1'}),
          );
          expect(response.statusCode, 200);
          expect(rig.adapter.sent, hasLength(2));
          expect(rig.adapter.sent.map((s) => s.method), ['PUT', 'PUT']);
          rig.expectDistinctJtis();
        },
      );

      test(
        "the proof's htm and htu are the send's method and URL without query or fragment",
        () async {
          final rig = await Rig.create(order, [const Step(200)]);
          await rig.dio.get<String>('$orders?page=2&sort=asc#top');
          final sent = rig.adapter.sent.single;
          expect(sent.method, 'GET');
          expect(sent.claims['htm'], 'GET');
          expect(sent.claims['htu'], orders);
          expect(sent.uri.query, 'page=2&sort=asc');
        },
      );
    });
  }
}
