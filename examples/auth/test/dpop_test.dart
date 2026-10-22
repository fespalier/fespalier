// DPoP (RFC 9449) with fespalier_keypair_dpop, against the demo server in `requireDpop` mode: it
// checks every proof with verifyDpopProof, binds the code and the tokens to the key, asks for a
// nonce at the API, and refuses a clock that is wrong. FakeKeypairSigner is the key: the same on
// every run, and no platform. (The real thing, a real Keycloak, is
// `packages/fespalier_keypair_dpop/test/keycloak_live_test.dart`.)
import 'dart:convert';

import 'package:auth/api.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

import 'support.dart';

final issuer = Uri.parse(DemoServer.issuer);
final redirect = Uri.parse('com.example.fespalierauth:/callback');
const tokenCall = 'POST /oidc/protocol/openid-connect/token';

/// The thumbprints of FakeKeypairSigner's keys, made with python (see the keypair package's
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

/// The backend of [server]'s provider, with [proof]; its token calls go through [transport] (the
/// server by default).
OidcBackend backend(
  DemoServer server,
  DpopProof proof, {
  HttpTransport? transport,
}) => OidcBackend(
  issuer: issuer,
  clientId: 'fespalier-auth-example-dpop',
  redirectUri: redirect,
  endpoints: OidcEndpoints.keycloak(issuer),
  openBrowser: (url, back) => browser(url, back, server),
  transport: transport ?? server.transport,
  proof: proof,
);

/// The app over [oidc]: the one transport is [base] (the server by default), as `startup()` makes it.
ProviderContainer app(
  DemoServer server,
  OidcBackend oidc, {
  HttpTransport? base,
  TokenStore? store,
}) {
  final container = ProviderContainer(
    overrides: [
      authConfig.overrideWithValue(
        AuthConfig(
          backend: oidc,
          transport: base ?? server.transport,
          store: store ?? MemoryTokenStore(),
          apiOrigins: [apiOrigin],
        ),
      ),
      authInitialState.overrideWithValue(const SignedOut()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The tokens a session holds.
TokenCredential tokensOf(AuthSession session) =>
    session.credential as TokenCredential;

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
        final dpop = DpopProof(signer: FakeKeypairSigner());
        final session = await signIn(app(server, backend(server, dpop)));
        expect(tokensOf(session).tokenType, 'DPoP');
        expect(tokensOf(session).isDpop, isTrue);
        expect(tokensOf(session).jkt, firstKey);
        expect(server.acceptedProofs, [tokenCall]);
        // The access token says which key it belongs to (cnf.jkt, RFC 9449 section 6.1).
        final claims =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize(
                        tokensOf(session).accessToken.split('.')[1],
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
          backend(server, DpopProof(signer: FakeKeypairSigner())),
        );
        final session = await signIn(container);
        final ok = await get(container.read(authTransport), '/orders');
        expect(ok.status, 200);
        expect(server.acceptedProofs, [tokenCall, 'GET /orders']);
        // Sent by hand, the token alone is no use.
        final bearer = await server.client.get(
          api('/orders'),
          headers: {'Authorization': 'Bearer ${tokensOf(session).accessToken}'},
        );
        expect(bearer.statusCode, 401);
        expect(
          bearer.headers['www-authenticate'],
          'Bearer error="invalid_token"',
        );
        final dpopNoProof = await server.client.get(
          api('/orders'),
          headers: {'Authorization': 'DPoP ${tokensOf(session).accessToken}'},
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
        backend(server, DpopProof(signer: FakeKeypairSigner())),
      );
      final session = await signIn(container);
      final thief = DpopProof(signer: FakeKeypairSigner(seed: 'a thief'));
      final headers = await thief.headers(
        method: 'GET',
        uri: api('/orders'),
        accessToken: tokensOf(session).accessToken,
      );
      final response = await server.client.get(
        api('/orders'),
        headers: {
          'Authorization': 'DPoP ${tokensOf(session).accessToken}',
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
          backend(server, DpopProof(signer: FakeKeypairSigner())),
        );
        await signIn(container);
        final transport = container.read(authTransport);
        expect((await get(transport, '/orders')).status, 200);
        expect(server.refusedProofs, ['use_dpop_nonce']);
        expect(server.acceptedProofs, [tokenCall, 'GET /orders']);
        // The nonce was kept: the next request is not challenged.
        expect((await get(transport, '/orders/1')).status, 200);
        expect(server.refusedProofs, ['use_dpop_nonce']);
        expect(server.acceptedProofs.last, 'GET /orders/1');
      });
    },
  );

  test(
    'a renewal carries a proof of the same key, and the next request a new token',
    () async {
      await onClock(() async {
        final server = DemoServer(requireDpop: true);
        final container = app(
          server,
          backend(server, DpopProof(signer: FakeKeypairSigner())),
        );
        final first = await signIn(container);
        now = now.add(const Duration(minutes: 6));
        final response = await get(container.read(authTransport), '/orders');
        expect(response.status, 200);
        expect(server.acceptedProofs, [tokenCall, tokenCall, 'GET /orders']);
        final next = (container.read(authSession) as SignedIn).session;
        expect(tokensOf(next).accessToken, isNot(tokensOf(first).accessToken));
        expect(
          tokensOf(next).refreshToken,
          isNot(tokensOf(first).refreshToken),
          reason: 'rotated',
        );
        expect(tokensOf(next).jkt, firstKey);
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
        final dpop = DpopProof(signer: FakeKeypairSigner());
        final container = app(server, backend(server, dpop));
        await signIn(container);
        expect(server.refusedProofs, ['invalid_dpop_proof']);
        expect(dpop.clockOffset, const Duration(minutes: 2));
        // The correction applies to the next request: no refusal.
        expect(
          (await get(container.read(authTransport), '/orders')).status,
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
        final signer = FakeKeypairSigner();
        final container = app(
          server,
          backend(server, DpopProof(signer: signer)),
        );
        expect(tokensOf(await signIn(container)).jkt, firstKey);
        await container.read(authSession.notifier).signOut();
        expect(signer.deletes, 1);
        expect(container.read(authSession), isA<SignedOut>());
        expect(tokensOf(await signIn(container)).jkt, secondKey);
      });
    },
  );

  test('a refresh token is no use with another key: AuthRejected', () async {
    await onClock(() async {
      final server = DemoServer(requireDpop: true);
      final dpop = DpopProof(signer: FakeKeypairSigner());
      final oidc = backend(server, dpop);
      final session = await oidc.signIn(const BrowserSignIn());
      await dpop.reset(); // the key is gone
      await expectLater(
        oidc.renew(session),
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
          app(server, backend(server, DpopProof(signer: FakeKeypairSigner()))),
        );
        expect(tokensOf(session).jkt, firstKey);
        // The app starts again, on a device whose key is another one (a restored backup).
        final restored =
            restoreAuth(
                  AuthConfig(
                    backend: backend(
                      server,
                      DpopProof(
                        signer: FakeKeypairSigner(seed: 'another device'),
                      ),
                    ),
                    transport: server.transport,
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
      'under the session transport re-sends one proof, which the server refuses; over it, each attempt has its own',
      () async {
        await onClock(() async {
          // Under: the retrier sits in the one transport, below the session, so the same headers
          // go twice.
          final under = DemoServer(requireDpop: true);
          final retrying = HttpClientTransport(
            RetryClient(
              Flaky(under.client),
              retries: 1,
              delay: (_) => Duration.zero,
            ),
          );
          final underContainer = app(
            under,
            backend(
              under,
              DpopProof(signer: FakeKeypairSigner()),
              transport: retrying,
            ),
            base: retrying,
          );
          await signIn(underContainer);
          await get(underContainer.read(authTransport), '/orders');
          expect(
            under.refusedProofs,
            contains('invalid_dpop_proof'),
            reason: 'the re-sent proof was refused',
          );
          expect(under.reusedProofs, 1, reason: 'as a reused jti');

          // Over: the retrier sends through the session transport, as an http.Client
          // (TransportClient), so every attempt is signed afresh and nothing is refused.
          final over = DemoServer(requireDpop: true);
          final flaky = HttpClientTransport(Flaky(over.client));
          final overContainer = app(
            over,
            backend(
              over,
              DpopProof(signer: FakeKeypairSigner()),
              transport: flaky,
            ),
            base: flaky,
          );
          await signIn(overContainer);
          final client = RetryClient(
            TransportClient(overContainer.read(authTransport)),
            retries: 1,
            when: (response) => response.statusCode == 503,
            delay: (_) => Duration.zero,
          );
          final response = await client.get(api('/orders'));
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
