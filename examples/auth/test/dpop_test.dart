// DPoP (RFC 9449) with fespalier_sign_keypair, against the demo server in `requireDpop` mode: it
// checks every proof with verifyDpopProof, binds the code and the tokens to the key, asks for a
// nonce at the API, and refuses a clock that is wrong. FakeDpopSigner is the key: the same on every
// run, and no platform. (The real thing, a real Keycloak, is
// `packages/fespalier_sign_keypair/test/keycloak_live_test.dart`.)
import 'dart:convert';

import 'package:auth/api.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/oidc.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

final issuer = Uri.parse(DemoServer.issuer);
final redirect = Uri.parse('com.example.fespalierauth:/callback');
const tokenCall = 'POST /oidc/protocol/openid-connect/token';

/// The thumbprints of FakeDpopSigner's keys, made with python (see the sign_keypair package's
/// thumbprint_test.dart).
const firstKey = 'XCW8GJrJxRT2sQyX29vGikHXwr7aK5puMdwvhd9pqNE';
const secondKey = 'kSFjtX3PWG7XxFarb-p54ae5WE7C7nIbuoo5V2zbE20';

var now = DateTime.utc(2026, 10, 3, 12);

/// Runs [body] on the test's clock, which [now] moves.
Future<T> onClock<T>(Future<T> Function() body) =>
    withClock(Clock(() => now), body);

Future<Uri> browser(Uri url, Uri back, DemoServer server) async {
  final response = await server.client.get(url);
  return Uri.parse(response.headers['location']!);
}

OidcBackend backend(DemoServer server, DpopProof proof) => OidcBackend(
  issuer: issuer,
  clientId: 'fespalier-auth-example-dpop',
  redirectUri: redirect,
  endpoints: OidcEndpoints.keycloak(issuer),
  openBrowser: (url, back) => browser(url, back, server),
  client: server.client,
  proof: proof,
);

ProviderContainer app(
  DemoServer server,
  OidcBackend oidc, {
  http.Client? base,
  TokenStore? store,
}) {
  final container = ProviderContainer(
    overrides: [
      authConfig.overrideWithValue(
        AuthConfig(
          backend: oidc,
          store: store ?? MemoryTokenStore(),
          apiOrigins: [apiOrigin],
        ),
      ),
      authInitialState.overrideWithValue(const SignedOut()),
      authBaseClient.overrideWithValue(base ?? server.client),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<AuthSession> signIn(ProviderContainer container) async {
  await container.read(authSession.notifier).signIn(const BrowserSignIn());
  return (container.read(authSession) as SignedIn).session;
}

/// A client that forwards a request to the server, and then says "503" to the first GET /orders:
/// the server saw the proof, the caller does not know it.
final class Flaky extends http.BaseClient {
  Flaky(this.inner);

  final http.Client inner;
  int orders = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (request.url.path == '/orders' && ++orders == 1) {
      await response.stream.drain<void>();
      return http.StreamedResponse(const Stream.empty(), 503, request: request);
    }
    return response;
  }
}

void main() {
  setUp(() => now = DateTime.utc(2026, 10, 3, 12));

  test(
    'signs in: the code is bound to the key, the tokens are DPoP and bound to it',
    () async {
      await onClock(() async {
        final server = DemoServer(requireDpop: true);
        final dpop = DpopProof(signer: FakeDpopSigner());
        final session = await signIn(app(server, backend(server, dpop)));
        expect(session.tokens.tokenType, 'DPoP');
        expect(session.tokens.isDpop, isTrue);
        expect(session.binding, firstKey);
        expect(server.acceptedProofs, [tokenCall]);
        // The access token says which key it belongs to (cnf.jkt, RFC 9449 section 6.1).
        final claims =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize(
                        session.tokens.accessToken.split('.')[1],
                      ),
                    ),
                  ),
                )
                as Map<String, Object?>;
        expect((claims['cnf']! as Map)['jkt'], firstKey);
      });
    },
  );

  test(
    'the API takes the DPoP scheme with a proof, and refuses a bearer header for the same token',
    () async {
      await onClock(() async {
        final server = DemoServer(requireDpop: true);
        final container = app(
          server,
          backend(server, DpopProof(signer: FakeDpopSigner())),
        );
        final session = await signIn(container);
        final ok = await container.read(authHttpClient).get(api('/orders'));
        expect(ok.statusCode, 200);
        expect(server.acceptedProofs, [tokenCall, 'GET /orders']);
        // Sent by hand, the token alone is no use.
        final bearer = await server.client.get(
          api('/orders'),
          headers: {'Authorization': 'Bearer ${session.tokens.accessToken}'},
        );
        expect(bearer.statusCode, 401);
        expect(
          bearer.headers['www-authenticate'],
          'Bearer error="invalid_token"',
        );
        final dpopNoProof = await server.client.get(
          api('/orders'),
          headers: {'Authorization': 'DPoP ${session.tokens.accessToken}'},
        );
        expect(dpopNoProof.statusCode, 401);
        expect(
          dpopNoProof.headers['www-authenticate'],
          startsWith('DPoP algs="ES256", error="invalid_token"'),
        );
      });
    },
  );

  test('a token is no use with the proof of another key', () async {
    await onClock(() async {
      final server = DemoServer(requireDpop: true);
      final container = app(
        server,
        backend(server, DpopProof(signer: FakeDpopSigner())),
      );
      final session = await signIn(container);
      final thief = DpopProof(signer: FakeDpopSigner(seed: 'a thief'));
      final headers = await thief.headers(
        method: 'GET',
        uri: api('/orders'),
        accessToken: session.tokens.accessToken,
      );
      final response = await server.client.get(
        api('/orders'),
        headers: {
          'Authorization': 'DPoP ${session.tokens.accessToken}',
          ...headers,
        },
      );
      expect(response.statusCode, 401);
      expect(
        response.headers['www-authenticate'],
        contains(
          'error="invalid_dpop_proof", error_description="the key\'s thumbprint is',
        ),
      );
    });
  });

  test(
    'an API nonce challenge is answered once, and the nonce is kept',
    () async {
      await onClock(() async {
        final server = DemoServer(requireDpop: true, apiNonce: 'demo-nonce-1');
        final container = app(
          server,
          backend(server, DpopProof(signer: FakeDpopSigner())),
        );
        await signIn(container);
        final client = container.read(authHttpClient);
        expect((await client.get(api('/orders'))).statusCode, 200);
        expect(server.refusedProofs, ['use_dpop_nonce']);
        expect(server.acceptedProofs, [tokenCall, 'GET /orders']);
        // The nonce was kept: the next request is not challenged.
        expect((await client.get(api('/orders/1'))).statusCode, 200);
        expect(server.refusedProofs, ['use_dpop_nonce']);
        expect(server.acceptedProofs.last, 'GET /orders/1');
      });
    },
  );

  test(
    'a refresh carries a proof of the same key, and the next request a new token',
    () async {
      await onClock(() async {
        final server = DemoServer(requireDpop: true);
        final container = app(
          server,
          backend(server, DpopProof(signer: FakeDpopSigner())),
        );
        final first = await signIn(container);
        now = now.add(const Duration(minutes: 6));
        final response = await container
            .read(authHttpClient)
            .get(api('/orders'));
        expect(response.statusCode, 200);
        expect(server.acceptedProofs, [tokenCall, tokenCall, 'GET /orders']);
        final next = (container.read(authSession) as SignedIn).session;
        expect(next.tokens.accessToken, isNot(first.tokens.accessToken));
        expect(
          next.tokens.refreshToken,
          isNot(first.tokens.refreshToken),
          reason: 'rotated',
        );
        expect(next.binding, firstKey);
        expect(server.refreshes, 1);
      });
    },
  );

  test(
    'a device clock that is behind is corrected once, from the Date header',
    () async {
      await onClock(() async {
        final server = DemoServer(
          requireDpop: true,
          clockSkew: const Duration(minutes: 2),
        );
        final dpop = DpopProof(signer: FakeDpopSigner());
        final container = app(server, backend(server, dpop));
        await signIn(container);
        expect(server.refusedProofs, ['invalid_dpop_proof']);
        expect(dpop.clockOffset, const Duration(minutes: 2));
        // The correction applies to the next request: no refusal.
        expect(
          (await container.read(authHttpClient).get(api('/orders'))).statusCode,
          200,
        );
        expect(server.refusedProofs, ['invalid_dpop_proof']);
      });
    },
  );

  test(
    'signing out rotates the key: the next sign-in is bound to a new one',
    () async {
      await onClock(() async {
        final server = DemoServer(requireDpop: true);
        final signer = FakeDpopSigner();
        final container = app(
          server,
          backend(server, DpopProof(signer: signer)),
        );
        expect((await signIn(container)).binding, firstKey);
        await container.read(authSession.notifier).signOut();
        expect(signer.deletes, 1);
        expect(container.read(authSession), isA<SignedOut>());
        expect((await signIn(container)).binding, secondKey);
      });
    },
  );

  test('a refresh token is no use with another key: AuthRejected', () async {
    await onClock(() async {
      final server = DemoServer(requireDpop: true);
      final dpop = DpopProof(signer: FakeDpopSigner());
      final oidc = backend(server, dpop);
      final session = await oidc.signIn(const BrowserSignIn());
      await dpop.reset(); // the key is gone
      await expectLater(
        oidc.refresh(session),
        throwsA(
          isA<AuthRejected>()
              .having((e) => e.error, 'error', 'invalid_grant')
              .having(
                (e) => e.description,
                'description',
                "DPoP confirmation doesn't match DPoP proof",
              ),
        ),
      );
    });
  });

  test(
    'a stored session whose key is gone is signed out at start-up: keyLost',
    () async {
      await onClock(() async {
        final server = DemoServer(requireDpop: true);
        final session = await signIn(
          app(server, backend(server, DpopProof(signer: FakeDpopSigner()))),
        );
        expect(session.binding, firstKey);
        // The app starts again, on a device whose key is another one (a restored backup).
        final restored =
            restoreAuth(
                  AuthConfig(
                    backend: backend(
                      server,
                      DpopProof(signer: FakeDpopSigner(seed: 'another device')),
                    ),
                    store: MemoryTokenStore(jsonEncode(session.toJson())),
                    apiOrigins: [apiOrigin],
                  ),
                )
                as Future<List<Override>>;
        final container = ProviderContainer(overrides: await restored);
        addTearDown(container.dispose);
        final state = container.read(authSession);
        expect(state, isA<SignedOut>());
        expect((state as SignedOut).reason, SignOutReason.keyLost);
      });
    },
  );

  group('RetryClient', () {
    test(
      'under the session client re-sends one proof, which the server refuses; over it, each attempt has its own',
      () async {
        await onClock(() async {
          // Under: the same headers go twice.
          final under = DemoServer(requireDpop: true);
          final underContainer = app(
            under,
            backend(under, DpopProof(signer: FakeDpopSigner())),
            base: RetryClient(
              Flaky(under.client),
              retries: 1,
              delay: (_) => Duration.zero,
            ),
          );
          await signIn(underContainer);
          await underContainer.read(authHttpClient).get(api('/orders'));
          expect(
            under.refusedProofs,
            contains('invalid_dpop_proof'),
            reason: 'the re-sent proof was refused',
          );
          expect(under.reusedProofs, 1, reason: 'as a reused jti');

          // Over: nothing is refused.
          final over = DemoServer(requireDpop: true);
          final overContainer = app(
            over,
            backend(over, DpopProof(signer: FakeDpopSigner())),
            base: Flaky(over.client),
          );
          await signIn(overContainer);
          final retrying = RetryClient(
            overContainer.read(authHttpClient),
            retries: 1,
            when: (response) => response.statusCode == 503,
            delay: (_) => Duration.zero,
          );
          final response = await retrying.get(api('/orders'));
          expect(response.statusCode, 200);
          expect(over.refusedProofs, isEmpty);
          expect(over.reusedProofs, 0);
          expect(over.acceptedProofs, [
            tokenCall,
            'GET /orders',
            'GET /orders',
          ]);
        });
      },
    );
  });
}
