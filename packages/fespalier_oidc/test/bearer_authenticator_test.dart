// BearerAuthenticator: the headers of a Bearer and of a DPoP-bound token, and what a response
// means for the session.
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_oidc/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final orders = Uri.parse('https://api.example.com/orders');

TransportRequest get(Uri uri) => TransportRequest(method: 'GET', uri: uri);

/// What the judge says, for a response of [status].
AuthVerdict judge(
  BearerAuthenticator authenticator,
  AuthSession session,
  int status, {
  Map<String, String> headers = const {},
  bool retried = false,
  String? body,
}) => authenticator.judge(
  session,
  get(orders),
  statusCode: status,
  headers: headers,
  body: body,
  retried: retried,
);

void main() {
  final bearer = fakeTokenSession(ada);
  final dpop = fakeTokenSession(ada, binding: 'thumb');

  group('headers', () {
    test('a Bearer token goes as Authorization: Bearer', () async {
      const authenticator = BearerAuthenticator();
      expect(await authenticator.headers(bearer, get(orders)), {
        'Authorization': 'Bearer fake-access-0',
      });
    });

    test(
      'a Bearer token on an authenticator with a proof gets no proof',
      () async {
        // Keycloak's refresh-token-only binding: the access token is a plain bearer token.
        final proof = FakeProof();
        final authenticator = BearerAuthenticator(proof: proof);
        expect(await authenticator.headers(bearer, get(orders)), {
          'Authorization': 'Bearer fake-access-0',
        });
        expect(proof.proofs, isEmpty);
      },
    );

    test(
      'a DPoP token goes as Authorization: DPoP, with the proof headers',
      () async {
        final proof = FakeProof();
        final authenticator = BearerAuthenticator(proof: proof);
        final headers = await authenticator.headers(
          dpop,
          get(Uri.parse('https://api.example.com/orders?page=2#top')),
        );
        expect(headers, {
          'Authorization': 'DPoP fake-access-0',
          'DPoP': 'fake-proof-1 GET https://api.example.com/orders ath',
        });
        expect(proof.proofs, hasLength(1));
      },
    );

    test(
      'the proof is for the request\'s method and URL, fresh on each call',
      () async {
        final proof = FakeProof();
        final authenticator = BearerAuthenticator(proof: proof);
        final first = await authenticator.headers(dpop, get(orders));
        final second = await authenticator.headers(
          dpop,
          TransportRequest(method: 'POST', uri: orders),
        );
        expect(
          first['DPoP'],
          'fake-proof-1 GET https://api.example.com/orders ath',
        );
        expect(
          second['DPoP'],
          'fake-proof-2 POST https://api.example.com/orders ath',
        );
      },
    );

    test('the token type is read case-insensitively', () async {
      final authenticator = BearerAuthenticator(proof: FakeProof());
      final lower = AuthSession(
        backend: 'oidc',
        credential: const TokenCredential(accessToken: 't', tokenType: 'dpop'),
        user: ada,
      );
      expect(
        (await authenticator.headers(lower, get(orders)))['Authorization'],
        'DPoP t',
      );
    });

    test(
      'a DPoP token and no proof is a StateError that says what to do',
      () async {
        const authenticator = BearerAuthenticator();
        await expectLater(
          authenticator.headers(dpop, get(orders)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                startsWith(
                  'fespalier_oidc: the access token is DPoP-bound (token_type DPoP), '
                  'but the backend has no proof of possession: pass proof: '
                  'DpopProof.device() (package:',
                ),
                endsWith(') to the backend'),
              ),
            ),
          ),
        );
      },
    );

    test('a session that holds another credential is a StateError', () async {
      final authenticator = BearerAuthenticator(proof: FakeProof());
      final foreign = AuthSession(
        backend: 'oidc',
        credential: const _OtherCredential(),
        user: ada,
      );
      await expectLater(
        authenticator.headers(foreign, get(orders)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not a TokenCredential'),
          ),
        ),
      );
      expect(
        () => authenticator.judge(
          foreign,
          get(orders),
          statusCode: 401,
          headers: const {},
          retried: false,
        ),
        throwsStateError,
        reason: 'a proof is asked about the token type, which needs a token',
      );
    });
  });

  group('judge', () {
    test('a 401 renews the session', () {
      const authenticator = BearerAuthenticator();
      final verdict = judge(authenticator, bearer, 401);
      expect(verdict, isA<Renew>());
      expect((verdict as Renew).hint, isNull);
    });

    test('a 401 with a WWW-Authenticate challenge and a body renews too', () {
      const authenticator = BearerAuthenticator();
      expect(
        judge(
          authenticator,
          bearer,
          401,
          headers: {'www-authenticate': 'Bearer error="invalid_token"'},
          body: '{"error":"invalid_token"}',
        ),
        isA<Renew>(),
      );
    });

    test('a 200 stands', () {
      const authenticator = BearerAuthenticator();
      expect(judge(authenticator, bearer, 200), isA<Accept>());
    });

    test('anything else stands: a 403, a 404, a 500', () {
      const authenticator = BearerAuthenticator();
      for (final status in [201, 204, 302, 400, 403, 404, 409, 500, 503]) {
        expect(
          judge(authenticator, bearer, status),
          isA<Accept>(),
          reason: '$status',
        );
      }
    });

    test('it never ends a session: no verdict is SessionEnded', () {
      const authenticator = BearerAuthenticator();
      for (var status = 100; status < 600; status += 1) {
        expect(
          judge(authenticator, bearer, status),
          isNot(isA<SessionEnded>()),
          reason: '$status',
        );
      }
    });

    test('a proof that asks for it makes a DPoP request a Resend', () {
      final proof = FakeProof()..challengeNext = true;
      final authenticator = BearerAuthenticator(proof: proof);
      expect(
        judge(authenticator, dpop, 401, headers: {'dpop-nonce': 'n'}),
        isA<Resend>(),
      );
      expect(proof.challenges, 1);
    });

    test('a Resend is for a nonce challenge, which is not a Renew', () {
      final proof = FakeProof()..challengeNext = true;
      final authenticator = BearerAuthenticator(proof: proof);
      expect(judge(authenticator, dpop, 401), isNot(isA<Renew>()));
      // The next 401 is no challenge: the token was refused.
      expect(judge(authenticator, dpop, 401), isA<Renew>());
    });

    test('never a Resend when the request was retried already', () {
      final proof = FakeProof()..challengeNext = true;
      final authenticator = BearerAuthenticator(proof: proof);
      expect(
        judge(authenticator, dpop, 401, retried: true),
        isA<Renew>(),
        reason:
            'a 401 that follows a resend stays a 401: the core stops at one renewal',
      );
      expect(judge(authenticator, dpop, 200, retried: true), isA<Accept>());
      expect(proof.challenges, 0);
      expect(proof.challengeNext, isTrue, reason: 'the proof was not tricked');
    });

    test('a proof sees the nonce of every DPoP response', () {
      final proof = FakeProof();
      final authenticator = BearerAuthenticator(proof: proof);
      expect(
        judge(authenticator, dpop, 200, headers: {'dpop-nonce': 'abc'}),
        isA<Accept>(),
      );
      expect(proof.nonce, 'abc');
    });

    test('a bearer token never asks the proof, challenge or not', () {
      final proof = FakeProof()..challengeNext = true;
      final authenticator = BearerAuthenticator(proof: proof);
      expect(judge(authenticator, bearer, 401), isA<Renew>());
      expect(judge(authenticator, bearer, 200), isA<Accept>());
      expect(proof.challenges, 0);
      expect(proof.challengeNext, isTrue);
    });

    test('with no proof a DPoP token is judged as a bearer one', () {
      const authenticator = BearerAuthenticator();
      expect(judge(authenticator, dpop, 401), isA<Renew>());
      expect(judge(authenticator, dpop, 200), isA<Accept>());
    });
  });
}

final class _OtherCredential implements SessionCredential {
  const _OtherCredential();

  @override
  DateTime? get expiresAt => null;

  @override
  DateTime? get renewableUntil => null;

  @override
  bool get renewable => true;

  @override
  Map<String, Object?> toJson() => const <String, Object?>{};
}
