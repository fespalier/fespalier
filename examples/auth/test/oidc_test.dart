// OidcBackend against the demo server's OpenID Connect provider, which is shaped like Keycloak and
// checks PKCE the way it does. The "browser" is a function that asks the provider for the redirect.
// (The real thing, a real Keycloak, is `packages/fespalier_auth/test/keycloak_live_test.dart`.)
import 'package:auth/api.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/oidc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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
  client: server.client,
);

ProviderContainer app(DemoServer server, OidcBackend oidc) {
  final container = ProviderContainer(
    overrides: [
      authConfig.overrideWithValue(
        AuthConfig(
          backend: oidc,
          store: MemoryTokenStore(),
          apiOrigins: [apiOrigin],
        ),
      ),
      authInitialState.overrideWithValue(const SignedOut()),
      authBaseClient.overrideWithValue(server.client),
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
      final next = await oidc.refresh(session);
      expect(next.tokens.refreshToken, isNot(session.tokens.refreshToken));
      await expectLater(
        oidc.refresh(session),
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
    'concurrent requests on an expired token refresh once: rotation would refuse a second',
    () async {
      final server = DemoServer();
      final container = app(server, backend(server));
      final notifier = container.read(authSession.notifier);
      await notifier.signIn(const BrowserSignIn());
      server.requests.clear();
      // The server forgets the access token: every request gets a 401 and asks for a refresh.
      server.expireAccessTokens();
      final client = container.read(authHttpClient);
      final responses = await Future.wait([
        client.get(api('/orders')),
        client.get(api('/orders/1')),
        client.get(api('/me')),
      ]);
      expect(responses.map((r) => r.statusCode), [200, 200, 200]);
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
    final found = await OidcEndpoints.discover(issuer, client: server.client);
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
      client: http.Client(),
    );
    await expectLater(
      oidc.signIn(const BrowserSignIn()),
      throwsA(isA<AuthCancelled>()),
    );
    expect(server.requests, isEmpty);
  });
}
