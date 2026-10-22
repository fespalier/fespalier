// A real DPoP proof (DpopProof over FakeKeypairSigner's software P-256 key) under fespalier_auth's
// SessionTransport, behind fespalier_dio's TransportAdapter, with dio_smart_retry on the Dio above
// it. The API plays a resource server and checks every send with verifyDpopProof: a proof that
// does not verify fails the test. The session is fespalier_oidc's: a real OidcBackend (renewing
// against a token endpoint that also verifies its proofs) and BearerAuthenticator. This proves
// the nonce, the ath, the DPoP header name and the single use of each proof with the real thing:
// every retry reaches SessionTransport.send again, so every send is signed afresh. Plain test():
// Dio starts its chain with Timer.run.
//
// The old SessionInterceptor could sit before or after the retrier, and this test ran both
// orders. The session is below the Dio now, in the transport, so there is only one order: the
// retrier is above it, always.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
import 'package:fespalier_keypair_dpop/verify.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
const orders = 'https://api.example.com/orders';
const ada = AuthUser(id: 'ada-id');
final issuer = Uri.parse('https://sso.example.com/realms/shop');

const nonceChallenge = {
  'DPoP-Nonce': 'srv-1',
  'WWW-Authenticate': 'DPoP error="use_dpop_nonce"',
};

/// One scripted answer; [onSend] runs when the request arrives, before the answer.
final class Step {
  const Step(this.status, {this.headers = const {}, this.onSend});

  final int status;
  final Map<String, String> headers;
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
/// the send's method, URL and access token, and against the nonce it last issued. A send with
/// neither `Authorization` nor `DPoP` is anonymous: it is recorded and answered 401, as a real
/// server would.
final class VerifyingTransport implements HttpTransport {
  VerifyingTransport(Iterable<Step> steps) : _steps = [...steps];

  final List<Step> _steps;
  final List<Sent> sent = [];

  /// The sends that carried no credential at all.
  final List<TransportRequest> anonymous = [];

  /// The proofs this server refused, with why; every case expects none.
  final List<String> refused = [];

  /// The nonce the server issued last: the next proof must carry it.
  String? nonce;

  List<String> get jtis => [for (final s in sent) s.jti];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    String? header(String name) {
      for (final e in request.headers.entries) {
        if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
      }
      return null;
    }

    final authorization = header('Authorization');
    final proof = header('DPoP');
    if (authorization == null && proof == null) {
      anonymous.add(request);
      return fakeResponse(401, body: 'no');
    }
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
        method: request.method,
        uri: request.uri,
        accessToken: authorization.substring('DPoP '.length),
        nonce: nonce,
      );
    } on DpopProofInvalid catch (error) {
      refused.add('send ${sent.length + 1}: $error');
      rethrow;
    }
    sent.add(
      Sent(
        method: request.method,
        uri: request.uri,
        authorization: authorization,
        proof: proof,
        claims: decoded.claims,
        replay: request.attributes[transportReplayKey] == true,
      ),
    );
    if (_steps.isEmpty) {
      throw StateError('VerifyingTransport: send ${sent.length} has no step');
    }
    final step = _steps.removeAt(0);
    await step.onSend?.call();
    final issued = step.headers['DPoP-Nonce'];
    if (issued != null) nonce = issued;
    return fakeResponse(
      step.status,
      body: step.status < 300 ? 'ok' : 'no',
      headers: {'content-type': 'text/plain', ...step.headers},
    );
  }
}

/// The token endpoint: verifies the proof of every request the way a server does and answers a
/// refresh with the next DPoP-bound access token (`fake-access-2`, `fake-access-3`, ...).
final class TokenServer {
  TokenServer() {
    transport = FakeTransport((request, body) {
      final proof = request.headers['DPoP'];
      if (proof == null) {
        refused.add('${request.uri}: no DPoP header');
        return fakeResponse(400, body: '{"error":"invalid_request"}');
      }
      try {
        verifyDpopProof(proof, method: request.method, uri: request.uri);
      } on DpopProofInvalid catch (error) {
        refused.add('${request.uri}: $error');
        return fakeResponse(400, body: '{"error":"invalid_dpop_proof"}');
      }
      final form = Uri.splitQueryString(utf8.decode(body));
      if (form['grant_type'] == 'refresh_token') {
        refreshes++;
        return fakeResponse(
          200,
          body: jsonEncode({
            'access_token': 'fake-access-${refreshes + 1}',
            'token_type': 'DPoP',
            'expires_in': 300,
            'refresh_token': 'fake-refresh-${refreshes + 1}',
          }),
          headers: {'content-type': 'application/json'},
        );
      }
      return fakeResponse(200);
    });
  }

  late final FakeTransport transport;

  /// How many refresh-token grants were answered.
  int refreshes = 0;

  /// The token-endpoint requests refused, with why; every case expects none.
  final List<String> refused = [];
}

/// The stack under test, signed in as [ada] with a key-bound session.
final class Rig {
  Rig._(this.container, this.adapter, this.token, this.dio);

  static Rig create(List<Step> steps) {
    final dpop = DpopProof(
      signer: FakeKeypairSigner(),
      random: CountingRandom(),
    );
    final token = TokenServer();
    final adapter = VerifyingTransport(steps);
    final backend = OidcBackend(
      issuer: issuer,
      clientId: 'shop-app',
      redirectUri: Uri.parse('com.example.shop:/callback'),
      endpoints: OidcEndpoints.keycloak(issuer),
      openBrowser: (url, redirect) => throw StateError('no browser'),
      transport: token.transport,
      proof: dpop,
    );
    final config = AuthConfig(
      backend: backend,
      transport: adapter,
      store: MemoryTokenStore(),
      apiOrigins: [api],
    );
    // Signed in with a session bound to the real key: fakeAuth's sessions are not.
    final container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(config),
        authInitialState.overrideWithValue(
          SignedIn(
            AuthSession(
              backend: backend.name,
              credential: TokenCredential(
                accessToken: 'fake-access-1',
                tokenType: 'DPoP',
                refreshToken: 'fake-refresh-1',
                jkt: fakeThumbprint0,
              ),
              user: ada,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() {
      expect(adapter.refused, isEmpty);
      expect(token.refused, isEmpty);
    });
    final dio = Dio()
      ..httpClientAdapter = TransportAdapter(
        SessionTransport(adapter, container.read(authorizer)),
      );
    dio.interceptors.add(
      RetryInterceptor(
        dio: dio,
        retries: 3,
        retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
        retryEvaluator: DefaultRetryEvaluator(
          defaultRetryableStatuses,
        ).evaluate,
      ),
    );
    return Rig._(container, adapter, token, dio);
  }

  final ProviderContainer container;
  final VerifyingTransport adapter;
  final TokenServer token;
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
  group('with the session under the Dio', () {
    test(
      'every retried send carries a proof the server accepts, with a jti never seen before',
      () async {
        final rig = Rig.create([
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
        expect(rig.token.refreshes, 0);
      },
    );

    test(
      "after a 401 the replay's ath is the refreshed token's hash",
      () async {
        final rig = Rig.create([const Step(401), const Step(200)]);
        final response = await rig.dio.get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.adapter.sent, hasLength(2));
        expect(rig.adapter.sent[0].ath, accessTokenHash('fake-access-1'));
        expect(rig.adapter.sent[1].ath, accessTokenHash('fake-access-2'));
        expect(rig.adapter.sent[1].authorization, 'DPoP fake-access-2');
        expect(rig.adapter.sent.map((s) => s.replay), [false, true]);
        rig.expectDistinctJtis();
        expect(rig.token.refreshes, 1);
      },
    );

    test(
      'a nonce challenge: the replayed proof carries the server\'s nonce',
      () async {
        final rig = Rig.create([
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
        expect(rig.token.refreshes, 0);
      },
    );

    test('a DPoP-Nonce on a 200 is used by the next request', () async {
      final rig = Rig.create([
        const Step(200, headers: {'DPoP-Nonce': 'srv-2'}),
        const Step(200),
      ]);
      await rig.dio.get<String>(orders);
      await rig.dio.get<String>(orders);
      expect(rig.adapter.sent[0].claims.containsKey('nonce'), isFalse);
      expect(rig.adapter.sent[1].nonce, 'srv-2');
      rig.expectDistinctJtis();
    });

    test(
      'a sign-out between a 503 and its retry: the retry is refused, carrying neither the stale token nor a proof, nor going out without them',
      () async {
        late final Rig rig;
        rig = Rig.create([
          Step(503, onSend: () => rig.notifier.signOut()),
          const Step(200),
        ]);
        final error = await failure(rig.dio.get<String>(orders));
        // The session is below the Dio, and the request's TransportMemo says it had the session:
        // the retry is refused (AuthRejected), as the old SessionInterceptor refused it, and
        // nothing goes out, stale or anonymous.
        expect(error.error, isA<AuthRejected>());
        expect(rig.adapter.sent, hasLength(1));
        expect(rig.adapter.anonymous, isEmpty);
        expect(rig.container.read(authSession), isA<SignedOut>());
      },
    );

    test(
      'a write with an Idempotency-Key retried after a 503 carries a new proof each time',
      () async {
        final rig = Rig.create([const Step(503), const Step(200)]);
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
        final rig = Rig.create([const Step(200)]);
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
