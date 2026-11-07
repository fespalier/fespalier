// The device authorization grant (RFC 8628), driven by hand: the provider is a
// FakeDeviceAuthorizationServer behind a FakeTransport, every wait is a FakeDeviceWait the test
// ends, and the clock is a TestTime. Nothing here waits for real time.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_oidc/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final issuer = Uri.parse('https://sso.example.com/realms/tv');
final endpoints = OidcEndpoints.keycloak(issuer);
const clientId = 'tv-app';

/// A provider, the transport in front of it, and the user's clock.
final class Rig {
  Rig({
    int? interval = 5,
    int expiresIn = 600,
    this.proof,
    OidcEndpoints? known,
    FutureOr<TransportResponse>? Function(TransportRequest, Uint8List)? before,
  }) : server = FakeDeviceAuthorizationServer(
         deviceEndpoint: endpoints.deviceAuthorization!,
         tokenEndpoint: endpoints.token,
         verificationUriComplete: Uri.parse(
           'https://sso.example.com/realms/tv/device?user_code=WDJB-MJHT',
         ),
         interval: interval,
         expiresIn: expiresIn,
       ),
       known = known ?? endpoints {
    transport = FakeTransport((request, body) {
      final answer = before?.call(request, body);
      return answer ?? server.handle(request, body);
    });
    wait = FakeDeviceWait(onElapse: time.elapse);
  }

  final FakeDeviceAuthorizationServer server;
  final ProofOfPossession? proof;
  final OidcEndpoints known;
  late final FakeTransport transport;
  final time = TestTime();
  late final FakeDeviceWait wait;
  final codes = <DeviceCode>[];

  late final backend = OidcBackend(
    issuer: issuer,
    clientId: clientId,
    // A device-only backend: no browser, no redirect.
    endpoints: known,
    transport: transport,
    proof: proof,
    random: Random(1),
  );

  /// Starts a sign-in on the test's clock; the future is caught so a test can expect its error.
  Future<AuthSession> signIn({
    Future<void>? cancel,
    List<String>? scopes,
    Map<String, String> parameters = const {},
  }) => time.run(
    () => backend.signIn(
      DeviceSignIn(
        onCode: codes.add,
        wait: wait.call,
        cancel: cancel,
        scopes: scopes,
        parameters: parameters,
      ),
    ),
  );
}

String idToken({String iss = 'https://sso.example.com/realms/tv'}) => jwt({
  'iss': iss,
  'aud': clientId,
  'sub': 'u-1',
  'email': 'ada@example.com',
});

void main() {
  test(
    'asks for a code, shows it, polls while pending, and signs in with the tokens',
    () async {
      final rig = Rig();
      final signedIn = rig.signIn(scopes: ['openid', 'offline_access']);
      expect(await rig.wait.next, const Duration(seconds: 5));

      // The code request: no proof, the client and the scopes.
      expect(rig.server.codeRequests.single, {
        'client_id': clientId,
        'scope': 'openid offline_access',
      });
      final code = rig.codes.single;
      expect(code.userCode, 'WDJB-MJHT');
      expect(code.verificationUri.toString(), 'https://sso.example.com/device');
      expect(
        code.verificationUriComplete?.queryParameters['user_code'],
        'WDJB-MJHT',
      );
      expect(code.interval, const Duration(seconds: 5));
      expect(code.expiresAt, rig.time.now.add(const Duration(minutes: 10)));
      expect(code.toString(), isNot(contains(rig.server.deviceCode)));

      // Two pending polls, then the user approves.
      rig.wait.elapse();
      await rig.wait.next;
      rig.wait.elapse();
      await rig.wait.next;
      expect(rig.server.polls, hasLength(2));
      expect(rig.server.polls.first, {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': rig.server.deviceCode,
        'client_id': clientId,
      });
      rig.server.approve(
        claims: {'sub': 'u-1'},
        extra: {'refresh_token': 'refresh-1', 'id_token': idToken()},
      );
      rig.wait.elapse();
      final session = await signedIn;

      final tokens = session.credential as TokenCredential;
      expect(session.backend, 'oidc');
      expect(session.user.id, 'u-1');
      expect(session.user.email, 'ada@example.com');
      expect(tokens.refreshToken, 'refresh-1');
      expect(tokens.jkt, isNull);
      expect(rig.server.polls, hasLength(3));
      expect(rig.wait.intervals, everyElement(const Duration(seconds: 5)));
      expect(rig.wait.isWaiting, isFalse);
    },
  );

  test(
    'the backend scopes and extra fields go into the code request',
    () async {
      final rig = Rig();
      unawaited(
        rig
            .signIn(parameters: {'audience': 'tv'})
            .catchError((_) => fakeSessionFor()),
      );
      await rig.wait.next;
      expect(rig.server.codeRequests.single, {
        'client_id': clientId,
        'scope': 'openid profile email',
        'audience': 'tv',
      });
    },
  );

  test('no interval in the answer is 5 seconds', () async {
    final rig = Rig(interval: null);
    unawaited(rig.signIn().catchError((_) => fakeSessionFor()));
    expect(await rig.wait.next, const Duration(seconds: 5));
  });

  test('slow_down adds 5 seconds to every later wait', () async {
    final rig = Rig();
    final signedIn = rig.signIn();
    await rig.wait.next;
    rig.server.slowDownNext();
    rig.wait.elapse();
    expect(await rig.wait.next, const Duration(seconds: 10));
    rig.wait.elapse(); // pending
    expect(await rig.wait.next, const Duration(seconds: 10));
    rig.server.slowDownNext();
    rig.wait.elapse();
    expect(await rig.wait.next, const Duration(seconds: 15));
    rig.server.approve();
    rig.wait.elapse();
    await signedIn;
    expect(rig.wait.intervals, [
      const Duration(seconds: 5),
      const Duration(seconds: 10),
      const Duration(seconds: 10),
      const Duration(seconds: 15),
    ]);
  });

  test('access_denied is AuthRejected and polls no more', () async {
    final rig = Rig();
    final signedIn = rig.signIn();
    await rig.wait.next;
    rig.server.deny();
    rig.wait.elapse();
    await expectLater(
      signedIn,
      throwsA(
        isA<AuthRejected>().having((e) => e.error, 'error', 'access_denied'),
      ),
    );
    expect(rig.server.polls, hasLength(1));
    expect(rig.wait.isWaiting, isFalse);
  });

  test("the provider's expired_token is AuthRejected", () async {
    final rig = Rig();
    final signedIn = rig.signIn();
    await rig.wait.next;
    rig.server.expire();
    rig.wait.elapse();
    await expectLater(
      signedIn,
      throwsA(
        isA<AuthRejected>().having((e) => e.error, 'error', 'expired_token'),
      ),
    );
  });

  test(
    'a code past its expires_in is expired_token without another poll',
    () async {
      final rig = Rig(expiresIn: 12);
      final signedIn = rig.signIn();
      await rig.wait.next;
      rig.wait.elapse(); // t = 5 s: pending
      await rig.wait.next;
      rig.wait.elapse(); // t = 10 s: pending
      await rig.wait.next;
      rig.wait.elapse(); // t = 15 s: past the 12 s
      await expectLater(
        signedIn,
        throwsA(
          isA<AuthRejected>().having((e) => e.error, 'error', 'expired_token'),
        ),
      );
      expect(rig.server.polls, hasLength(2));
    },
  );

  test(
    'cancel during a wait is AuthCancelled, at once and with no poll',
    () async {
      final rig = Rig();
      final cancel = Completer<void>();
      final signedIn = rig.signIn(cancel: cancel.future);
      await rig.wait.next;
      cancel.complete();
      await expectLater(signedIn, throwsA(isA<AuthCancelled>()));
      expect(rig.server.polls, isEmpty);
      // The app's wait ending later changes nothing.
      rig.wait.elapse();
      await pumpEventQueue();
      expect(rig.server.polls, isEmpty);
    },
  );

  test('cancel while a poll is in flight aborts it', () async {
    final inFlight = Completer<void>();
    late final Rig rig;
    rig = Rig(
      before: (request, body) {
        if (request.uri.path == endpoints.token.path) {
          expect(request.abortTrigger, isNotNull);
          inFlight.complete();
          return Completer<TransportResponse>().future;
        }
        return null;
      },
    );
    final cancel = Completer<void>();
    final signedIn = rig.signIn(cancel: cancel.future);
    await rig.wait.next;
    rig.wait.elapse();
    await inFlight.future;
    cancel.complete();
    await expectLater(signedIn, throwsA(isA<AuthCancelled>()));
    // The poll in flight was aborted (the fake also counts the code request, answered long
    // before, whose trigger is the same future).
    expect(rig.transport.abortCount, greaterThanOrEqualTo(1));
    expect(rig.server.polls, isEmpty);
  });

  test(
    'cancel before the code arrives is AuthCancelled, and no code is shown',
    () async {
      final rig = Rig();
      final cancel = Completer<void>()..complete();
      await expectLater(
        rig.signIn(cancel: cancel.future),
        throwsA(isA<AuthCancelled>()),
      );
      expect(rig.codes, isEmpty);
    },
  );

  test(
    'a poll that could not be sent waits twice as long and polls again',
    () async {
      var fail = true;
      late final Rig rig;
      rig = Rig(
        before: (request, body) {
          if (fail && request.uri.path == endpoints.token.path) {
            fail = false;
            throw TransportUnsent(null, request.uri);
          }
          return null;
        },
      );
      final signedIn = rig.signIn();
      await rig.wait.next;
      rig.wait.elapse();
      expect(await rig.wait.next, const Duration(seconds: 10));
      rig.server.approve();
      rig.wait.elapse();
      await signedIn;
    },
  );

  test(
    'a poll the server may have run (a broken connection) ends the sign-in',
    () async {
      late final Rig rig;
      rig = Rig(
        before: (request, body) {
          if (request.uri.path == endpoints.token.path) {
            throw TransportBroken(null, request.uri);
          }
          return null;
        },
      );
      final signedIn = rig.signIn();
      await rig.wait.next;
      rig.wait.elapse();
      await expectLater(signedIn, throwsA(isA<TransportBroken>()));
    },
  );

  group('DPoP', () {
    test(
      'every poll carries a fresh proof, the code request none, and the tokens are bound',
      () async {
        final proof = FakeProof(thumbprintValue: 'jkt-1');
        final rig = Rig(proof: proof);
        final signedIn = rig.signIn();
        await rig.wait.next;
        expect(proof.proofs, isEmpty);
        rig.wait.elapse();
        await rig.wait.next;
        rig.server.approve(tokenType: 'DPoP');
        rig.wait.elapse();
        final session = await signedIn;
        expect(rig.server.pollHeaders.map((h) => h['dpop']), [
          'fake-proof-1 POST ${endpoints.token}',
          'fake-proof-2 POST ${endpoints.token}',
        ]);
        expect((session.credential as TokenCredential).jkt, 'jkt-1');
        expect(rig.backend.scheme, 'dpop');
      },
    );

    test(
      'a nonce challenge on a poll is answered once with a new proof',
      () async {
        final proof = FakeProof();
        var challenged = false;
        final rig = Rig(
          proof: proof,
          before: (request, body) {
            if (challenged || request.uri.path != endpoints.token.path) {
              return null;
            }
            challenged = true;
            // What DpopProof does with a use_dpop_nonce.
            proof.challengeNext = true;
            return fakeResponse(
              400,
              body: '{"error":"use_dpop_nonce"}',
              headers: {'DPoP-Nonce': 'n-1'},
            );
          },
        );
        final signedIn = rig.signIn();
        await rig.wait.next;
        rig.server.approve(tokenType: 'DPoP');
        rig.wait.elapse();
        await signedIn;
        expect(proof.challenges, 1);
        // The resend went at once, without another wait, with the new nonce.
        expect(rig.wait.intervals, hasLength(1));
        expect(
          rig.server.pollHeaders.single['dpop'],
          endsWith('nonce=nonce-1'),
        );
      },
    );
  });

  group('errors', () {
    test('a provider with no device endpoint is an OidcException', () async {
      final rig = Rig(
        known: OidcEndpoints(
          authorization: endpoints.authorization,
          token: endpoints.token,
        ),
      );
      await expectLater(
        rig.signIn(),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            contains('device_authorization_endpoint'),
          ),
        ),
      );
      expect(rig.transport.requests, isEmpty);
    });

    test(
      'a refused code request is AuthRejected with its OAuth error',
      () async {
        final rig = Rig(
          before: (request, body) => request.uri.path.endsWith('/device')
              ? fakeResponse(
                  401,
                  body: jsonEncode({
                    'error': 'invalid_client',
                    'error_description': 'Client authentication failed',
                  }),
                )
              : null,
        );
        await expectLater(
          rig.signIn(),
          throwsA(
            isA<AuthRejected>()
                .having((e) => e.error, 'error', 'invalid_client')
                .having(
                  (e) => e.description,
                  'description',
                  'Client authentication failed',
                ),
          ),
        );
        expect(rig.codes, isEmpty);
      },
    );

    test('a 5xx at the code request is an OidcException', () async {
      final rig = Rig(
        before: (request, body) => request.uri.path.endsWith('/device')
            ? fakeResponse(503, body: '{"error":"server_error"}')
            : null,
      );
      await expectLater(rig.signIn(), throwsA(isA<OidcException>()));
    });

    test('a code answer without a user_code is an OidcException', () async {
      final rig = Rig(
        before: (request, body) => request.uri.path.endsWith('/device')
            ? fakeResponse(
                200,
                body: jsonEncode({
                  'device_code': 'd',
                  'verification_uri': 'https://x',
                  'expires_in': 600,
                }),
              )
            : null,
      );
      await expectLater(rig.signIn(), throwsA(isA<OidcException>()));
    });

    test('an unknown error while polling is AuthRejected with it', () async {
      final rig = Rig(
        before: (request, body) => request.uri.path == endpoints.token.path
            ? fakeResponse(400, body: '{"error":"invalid_grant"}')
            : null,
      );
      final signedIn = rig.signIn();
      await rig.wait.next;
      rig.wait.elapse();
      await expectLater(
        signedIn,
        throwsA(
          isA<AuthRejected>().having((e) => e.error, 'error', 'invalid_grant'),
        ),
      );
    });

    test(
      "an ID token from another issuer is refused, as a browser sign-in's",
      () async {
        final rig = Rig();
        final signedIn = rig.signIn();
        await rig.wait.next;
        rig.server.approve(
          extra: {'id_token': idToken(iss: 'https://evil.example.com')},
        );
        rig.wait.elapse();
        await expectLater(signedIn, throwsA(isA<OidcException>()));
      },
    );
  });

  group('endpoints', () {
    test("Keycloak's device endpoint is auth/device", () {
      expect(
        endpoints.deviceAuthorization.toString(),
        'https://sso.example.com/realms/tv/protocol/openid-connect/auth/device',
      );
    });

    test(
      'discovery reads device_authorization_endpoint, and leaves it null without',
      () async {
        Map<String, Object?> doc({bool device = true}) => {
          'issuer': issuer.toString(),
          'authorization_endpoint': '$issuer/authorize',
          'token_endpoint': '$issuer/token',
          if (device)
            'device_authorization_endpoint': '$issuer/device_authorization',
        };
        for (final device in [true, false]) {
          final found = await OidcEndpoints.discover(
            issuer,
            transport: FakeTransport.script([
              fakeResponse(200, body: jsonEncode(doc(device: device))),
            ]),
          );
          expect(
            found.deviceAuthorization?.toString(),
            device ? '$issuer/device_authorization' : isNull,
          );
        }
      },
    );

    test('a discovered device endpoint is the one the sign-in asks', () async {
      final deviceUrl = Uri.parse('$issuer/device_authorization');
      final server = FakeDeviceAuthorizationServer(
        deviceEndpoint: deviceUrl,
        tokenEndpoint: Uri.parse('$issuer/token'),
      );
      final transport = FakeTransport((request, body) {
        if (request.uri.path.endsWith('openid-configuration')) {
          return fakeResponse(
            200,
            body: jsonEncode({
              'issuer': issuer.toString(),
              'token_endpoint': '$issuer/token',
              'authorization_endpoint': '$issuer/authorize',
              'device_authorization_endpoint': deviceUrl.toString(),
            }),
          );
        }
        return server.handle(request, body);
      });
      final wait = FakeDeviceWait();
      final backend = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        transport: transport,
      );
      final signedIn = backend.signIn(
        DeviceSignIn(onCode: (_) {}, wait: wait.call),
      );
      await wait.next;
      server.approve();
      wait.elapse();
      await signedIn;
      expect(server.codeRequests, hasLength(1));
    });
  });

  group('a backend made without a browser', () {
    Matcher names(String what, String missing) => throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(
          startsWith(
            'fespalier_oidc: $what needs OidcBackend(openBrowser:, redirectUri:)',
          ),
          contains('made without $missing'),
        ),
      ),
    );

    test(
      'signs in with DeviceSignIn (the rig has neither) but refuses a BrowserSignIn',
      () async {
        final rig = Rig();
        expect(rig.backend.openBrowser, isNull);
        expect(rig.backend.redirectUri, isNull);
        await expectLater(
          rig.backend.signIn(const BrowserSignIn()),
          names('a BrowserSignIn', 'openBrowser and redirectUri'),
        );
        expect(rig.transport.requests, isEmpty);
      },
    );

    test('names the one argument that is missing', () async {
      final transport = FakeTransport.script(const []);
      final noRedirect = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        openBrowser: (_, _) => throw const AuthCancelled(),
        endpoints: endpoints,
        transport: transport,
      );
      await expectLater(
        noRedirect.signIn(const BrowserSignIn()),
        names('a BrowserSignIn', 'redirectUri'),
      );
      final noBrowser = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: Uri.parse('com.example.tv:/callback'),
        endpoints: endpoints,
        transport: transport,
      );
      await expectLater(
        noBrowser.signIn(const BrowserSignIn()),
        names('a BrowserSignIn', 'openBrowser'),
      );
      expect(transport.requests, isEmpty);
    });

    test('refuses a step-up and endBrowserSession the same way', () async {
      final rig = Rig();
      final session = fakeTokenSession(ada);
      await expectLater(
        rig.backend.stepUp(session, const StepUpChallenge()),
        names('a step-up', 'openBrowser and redirectUri'),
      );
      await expectLater(
        rig.backend.endBrowserSession(session),
        names('endBrowserSession', 'openBrowser and redirectUri'),
      );
      expect(rig.transport.requests, isEmpty);
    });
  });

  test('through the session notifier, the user ends signed in', () async {
    final rig = Rig();
    final container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(
          AuthConfig(
            backend: rig.backend,
            transport: rig.transport,
            store: SpyStore([]),
            apiOrigins: [Uri.parse('https://api.example.com')],
          ),
        ),
        authInitialState.overrideWithValue(const SignedOut()),
      ],
    );
    addTearDown(container.dispose);
    final signedIn = rig.time.run(
      () => container
          .read(authSession.notifier)
          .signIn(DeviceSignIn(onCode: rig.codes.add, wait: rig.wait.call)),
    );
    await rig.wait.next;
    rig.server.approve();
    rig.wait.elapse();
    await signedIn;
    expect(container.read(authSession), isA<SignedIn>());
  });
}

/// A placeholder for a sign-in a test leaves running.
AuthSession fakeSessionFor() => fakeTokenSession(ada);
