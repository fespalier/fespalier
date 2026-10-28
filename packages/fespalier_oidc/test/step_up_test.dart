// Step-up authentication (RFC 9470, since 0.25.0) with OpenID Connect, end to end on the real
// core: a 401 with `error="insufficient_user_authentication"` from the API makes the
// BearerAuthenticator answer StepUp, the OidcBackend signs the same user in again in the browser
// with `acr_values` / `max_age` (or `prompt=login`), and the request goes out again once. Also the
// session's authentication time, read from the ID token's `auth_time`.
import 'dart:math';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_oidc/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_provider.dart';
import 'support.dart';

final apiBase = Uri.parse('https://api.example.com');
final payouts = Uri.parse('https://api.example.com/payouts');

const stepUpChallenge =
    'Bearer error="insufficient_user_authentication", '
    'error_description="A different authentication level is required", '
    'acr_values="gold", max_age=60';

TransportRequest get(Uri uri) => TransportRequest(method: 'GET', uri: uri);

/// The API: 200 to an access token whose `acr` is [required], a step-up 401 to any other.
final class Api {
  String required = 'gold';
  String challenge = stepUpChallenge;

  late final FakeTransport transport = FakeTransport((request, _) {
    final token = request.headers['Authorization']?.split(' ').last;
    final acr = token == null ? null : unverifiedJwtClaims(token)?['acr'];
    if (acr == required) return fakeResponse(200, body: 'paid');
    return fakeResponse(401, headers: {'www-authenticate': challenge});
  });
}

final class Rig {
  Rig({Map<String, String> browserParams = const {}}) {
    oidc = OidcBackend(
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri,
      openBrowser: (url, redirect) {
        opened.add(url);
        // The provider authenticates at the level the URL asks for.
        final acr = url.queryParameters['acr_values'];
        provider.accessClaims = {'acr': acr?.split(' ').first ?? 'bronze'};
        provider.idClaims = {'auth_time': 1000 + opened.length};
        return browser(provider, params: browserParams)(url, redirect);
      },
      endpoints: endpoints,
      transport: provider.transport,
      random: Random(1),
    );
    container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(
          AuthConfig(
            backend: oidc,
            transport: provider.transport,
            store: MemoryTokenStore(),
            apiOrigins: [apiBase],
          ),
        ),
        authInitialState.overrideWithValue(const SignedOut()),
      ],
    );
    addTearDown(container.dispose);
    notifier = container.read(authSession.notifier);
    transport = SessionTransport(api.transport, container.read(authorizer));
  }

  final Server provider = Server();
  final Api api = Api();
  final List<Uri> opened = [];
  late final OidcBackend oidc;
  late final ProviderContainer container;
  late final AuthSessionNotifier notifier;
  late final SessionTransport transport;

  /// The authorization URLs after the sign-in's: the step-ups.
  List<Map<String, String>> get stepUps => [
    for (final url in opened.skip(1)) url.queryParameters,
  ];
}

void main() {
  group('BearerAuthenticator', () {
    final session = fakeTokenSession(ada);
    AuthVerdict judge(
      BearerAuthenticator authenticator,
      int status,
      Map<String, String> headers, {
      AuthSession? on,
    }) => authenticator.judge(
      on ?? session,
      get(payouts),
      statusCode: status,
      headers: headers,
      retried: false,
    );

    test('insufficient_user_authentication is a StepUp with its challenge', () {
      final verdict = judge(const BearerAuthenticator(), 401, {
        'www-authenticate': stepUpChallenge,
      });
      expect(verdict, isA<StepUp>());
      expect(
        (verdict as StepUp).challenge,
        const StepUpChallenge(
          acrValues: ['gold'],
          maxAge: Duration(minutes: 1),
        ),
      );
    });

    test('any other 401 still renews, and anything else stands', () {
      const authenticator = BearerAuthenticator();
      expect(judge(authenticator, 401, const {}), isA<Renew>());
      expect(
        judge(authenticator, 401, {
          'www-authenticate': 'Bearer error="invalid_token"',
        }),
        isA<Renew>(),
      );
      expect(
        judge(authenticator, 403, {'www-authenticate': stepUpChallenge}),
        isA<Accept>(),
      );
      expect(judge(authenticator, 200, const {}), isA<Accept>());
    });

    test('a DPoP step-up challenge is a StepUp; a nonce challenge still a '
        'Resend', () {
      final proof = FakeProof();
      final authenticator = BearerAuthenticator(proof: proof);
      final bound = fakeTokenSession(ada, binding: 'fake-thumbprint');
      expect(
        judge(authenticator, 401, {
          'www-authenticate':
              'DPoP algs="ES256", error="insufficient_user_authentication"',
        }, on: bound),
        isA<StepUp>(),
      );
      proof.challengeNext = true;
      expect(
        judge(authenticator, 401, {
          'www-authenticate': 'DPoP error="use_dpop_nonce"',
        }, on: bound),
        isA<Resend>(),
      );
    });
  });

  group('end to end', () {
    test('the sign-in reads auth_time into the session', () async {
      final rig = Rig();
      final session = await rig.notifier.signIn(const BrowserSignIn());
      expect(
        session.authenticatedAt,
        DateTime.fromMillisecondsSinceEpoch(1001 * 1000, isUtc: true),
      );
    });

    test(
      'a step-up refusal: one browser sign-in with acr_values and max_age, one retry',
      () async {
        final rig = Rig();
        await rig.notifier.signIn(const BrowserSignIn());
        final response = await rig.transport.send(get(payouts));
        expect(response.statusCode, 200);
        expect(rig.api.transport.requests, hasLength(2));
        expect(rig.stepUps, hasLength(1));
        final step = rig.stepUps.single;
        expect(step['acr_values'], 'gold');
        expect(step['max_age'], '60');
        expect(step.containsKey('prompt'), isFalse);
        expect(step['login_hint'], 'ada@example.com');
        expect(step['code_challenge_method'], 'S256');
        final session = rig.notifier.session!;
        expect(session.user.id, 'u-1');
        expect(
          session.authenticatedAt,
          DateTime.fromMillisecondsSinceEpoch(1002 * 1000, isUtc: true),
        );
        expect(
          (session.credential as TokenCredential).refreshToken,
          'refresh-2',
        );
      },
    );

    test('a challenge with neither parameter asks with prompt=login', () async {
      final rig = Rig();
      rig.api.challenge = 'Bearer error="insufficient_user_authentication"';
      rig.api.required = 'bronze';
      await rig.notifier.signIn(const BrowserSignIn(parameters: {'x': 'y'}));
      rig.api.required = 'never';
      await rig.transport.send(get(payouts));
      final step = rig.stepUps.single;
      expect(step['prompt'], 'login');
      expect(step.containsKey('acr_values'), isFalse);
      expect(step.containsKey('max_age'), isFalse);
    });

    test(
      'a second refusal is the answer: one browser sign-in, two sends, a 401',
      () async {
        final rig = Rig();
        await rig.notifier.signIn(const BrowserSignIn());
        rig.api.required = 'platinum';
        final response = await rig.transport.send(get(payouts));
        expect(response.statusCode, 401);
        expect(rig.api.transport.requests, hasLength(2));
        expect(rig.stepUps, hasLength(1));
        expect(rig.container.read(authSession), isA<SignedIn>());
      },
    );

    for (final (error, thrown) in [
      ('access_denied', isA<AuthCancelled>()),
      (
        'unmet_authentication_requirements',
        isA<AuthRejected>().having(
          (e) => e.error,
          'error',
          'unmet_authentication_requirements',
        ),
      ),
    ]) {
      test('the provider answers the step-up with $error: the 401 stands and '
          'the session stays', () async {
        final rig = _ErroringRig(error);
        await rig.signIn();
        final before = rig.container.read(authSession);
        final response = await rig.transport.send(get(payouts));
        expect(response.statusCode, 401);
        expect(rig.api.transport.requests, hasLength(1));
        expect(rig.container.read(authSession), before);
        await expectLater(
          rig.container
              .read(authSession.notifier)
              .stepUp(const StepUpChallenge()),
          throwsA(thrown),
        );
        expect(rig.container.read(authSession), before);
      });
    }

    test('a renewal keeps the authentication time', () async {
      final rig = Rig();
      final signedIn = await rig.notifier.signIn(const BrowserSignIn());
      rig.provider.idClaims = {};
      await rig.notifier.credential(forceRenew: true);
      expect(rig.notifier.session!.credential, isNot(signedIn.credential));
      expect(rig.notifier.session!.authenticatedAt, signedIn.authenticatedAt);
    });
  });
}

/// A rig whose browser signs in normally once, then answers every later authorization with
/// [error], as a provider that refuses or a user who cancels the step-up.
final class _ErroringRig {
  _ErroringRig(this.error) {
    var opens = 0;
    final oidc = OidcBackend(
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri,
      openBrowser: (url, redirect) {
        opens++;
        return browser(
          provider,
          params: opens == 1 ? const {} : {'error': error},
          without: opens == 1 ? const {} : const {'code'},
        )(url, redirect);
      },
      endpoints: endpoints,
      transport: provider.transport,
      random: Random(1),
    );
    container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(
          AuthConfig(
            backend: oidc,
            transport: provider.transport,
            store: MemoryTokenStore(),
            apiOrigins: [apiBase],
          ),
        ),
        authInitialState.overrideWithValue(const SignedOut()),
      ],
    );
    addTearDown(container.dispose);
    transport = SessionTransport(api.transport, container.read(authorizer));
  }

  final String error;
  final Server provider = Server();
  final Api api = Api();
  late final ProviderContainer container;
  late final SessionTransport transport;

  Future<void> signIn() =>
      container.read(authSession.notifier).signIn(const BrowserSignIn());
}
