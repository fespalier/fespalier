// OidcBackend against the demo server's OpenID Connect provider, which is shaped like Keycloak and
// checks PKCE the way it does. The "browser" is a function that asks the provider for the redirect.
// (The real thing, a real Keycloak, is `packages/fespalier_oidc/test/keycloak_live_test.dart`.)
import 'package:auth/api.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final issuer = Uri.parse(DemoServer.issuer);
final redirect = Uri.parse('com.example.fespalierauth:/callback');

/// What a browser does: follows the authorization URL, and returns where it ends up.
Future<Uri> Function(Uri, Uri) browser(
  DemoServer server, {
  Map<String, String> change = const {},
}) => (url, back) async {
  final altered = url.replace(
    queryParameters: {...url.queryParameters, ...change},
  );
  final response = await server.client.get(altered);
  return Uri.parse(response.headers['location']!);
};

OidcBackend backend(
  DemoServer server, {
  Map<String, String> change = const {},
}) => OidcBackend(
  issuer: issuer,
  clientId: 'fespalier-auth-example',
  redirectUri: redirect,
  endpoints: OidcEndpoints.keycloak(issuer),
  openBrowser: browser(server, change: change),
  transport: server.transport,
);

ProviderContainer app(DemoServer server, OidcBackend oidc) {
  final container = ProviderContainer(
    overrides: [
      authConfig.overrideWithValue(
        AuthConfig(
          backend: oidc,
          transport: server.transport,
          store: MemoryTokenStore(),
          apiOrigins: [apiOrigin],
        ),
      ),
      authInitialState.overrideWithValue(const SignedOut()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'signs in with PKCE, the user and the roles come from the tokens',
    () async {
      final server = DemoServer();
      final session = await backend(server).signIn(const BrowserSignIn());
      expect(session.user.name, 'Ada Example');
      expect(session.user.roles, contains('admin'));
      expect(session.user.email, 'ada@example.com');
      expect(server.logins, 1);
    },
  );

  test('login_hint chooses the user', () async {
    final server = DemoServer();
    final session = await backend(
      server,
    ).signIn(const BrowserSignIn(loginHint: 'bob'));
    expect(session.user.name, 'Bob Example');
    expect(session.user.roles, isNot(contains('admin')));
  });

  test(
    'the provider checks the PKCE challenge: a tampered one is refused',
    () async {
      final server = DemoServer();
      await expectLater(
        backend(
          server,
          change: {'code_challenge': 'forged'},
        ).signIn(const BrowserSignIn()),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            'the token endpoint answered HTTP 400: invalid_grant: PKCE verification failed: Code mismatch',
          ),
        ),
      );
    },
  );

  test(
    'prompt=none with no session is login_required: the sign-in fails with it',
    () async {
      final server = DemoServer();
      await expectLater(
        backend(server).signIn(const BrowserSignIn(prompt: 'none')),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            'the server answered the sign-in with error login_required',
          ),
        ),
      );
    },
  );

  test(
    'a refresh rotates the refresh token, and a replayed one is refused',
    () async {
      final server = DemoServer();
      final oidc = backend(server);
      final session = await oidc.signIn(const BrowserSignIn());
      final next = await oidc.renew(session);
      expect(
        (next.credential as TokenCredential).refreshToken,
        isNot((session.credential as TokenCredential).refreshToken),
      );
      await expectLater(
        oidc.renew(session),
        throwsA(
          isA<AuthRejected>().having(
            (e) => e.description,
            'description',
            'Maximum allowed refresh token reuse exceeded',
          ),
        ),
      );
    },
  );

  test(
    'concurrent requests on an expired token renew once: rotation would refuse a second',
    () async {
      final server = DemoServer();
      final container = app(server, backend(server));
      final notifier = container.read(authSession.notifier);
      await notifier.signIn(const BrowserSignIn());
      server.requests.clear();
      // The server forgets the access token: every request gets a 401 and asks for a renewal.
      server.expireAccessTokens();
      final transport = container.read(authTransport);
      final answers = await Future.wait([
        get(transport, '/orders'),
        get(transport, '/orders/1'),
        get(transport, '/me'),
      ]);
      expect(answers.map((a) => a.status), [200, 200, 200]);
      expect(server.refreshes, 1);
      expect(container.read(authSession), isA<SignedIn>());
    },
  );

  test('signing out revokes the refresh token at the provider', () async {
    final server = DemoServer();
    final container = app(server, backend(server));
    final notifier = container.read(authSession.notifier);
    await notifier.signIn(const BrowserSignIn());
    await notifier.signOut();
    expect(server.logouts, 1);
    expect(server.requests.last, 'POST /oidc/protocol/openid-connect/revoke');
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.user),
    );
  });

  test('the provider reached by discovery spells the same endpoints', () async {
    final server = DemoServer();
    final found = await OidcEndpoints.discover(
      issuer,
      transport: server.transport,
    );
    final spelled = OidcEndpoints.keycloak(issuer);
    expect(found.authorization, spelled.authorization);
    expect(found.token, spelled.token);
    expect(found.revocation, spelled.revocation);
    expect(found.endSession, spelled.endSession);
  });

  test('a browser that closes is a cancelled sign-in', () async {
    final server = DemoServer();
    final oidc = OidcBackend(
      issuer: issuer,
      clientId: 'fespalier-auth-example',
      redirectUri: redirect,
      endpoints: OidcEndpoints.keycloak(issuer),
      openBrowser: (_, _) async => throw const AuthCancelled(),
      transport: FakeTransport(
        (_, _) => throw StateError('no request is made'),
      ),
    );
    await expectLater(
      oidc.signIn(const BrowserSignIn()),
      throwsA(isA<AuthCancelled>()),
    );
    expect(server.requests, isEmpty);
  });
}
