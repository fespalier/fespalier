# `fespalier_auth` backends: OpenID Connect and Keycloak, Firebase, Supabase, your own API

Since 0.9.0. One interface, `AuthBackend`; the session, the store, the single-flight renewal and the guards do
not care which backend is behind it. First-party: **OpenID Connect** (`package:fespalier_oidc`, pure Dart, with
Keycloak's defaults; it was `package:fespalier_auth/oidc.dart` until 0.20.0) and the **device-signed** session of
[`auth-device-sessions.md`](auth-device-sessions.md) (`package:fespalier_sign_keypair`, since 0.21.0).
**Recipes** (code on this page, compiled by `just skill-samples`): Firebase, Supabase and a username-and-password API
of your own. The pieces are in [`auth-package.md`](auth-package.md).

Every backend gives `AuthConfig` the `transport:` its calls and the session's requests go through (since 0.21.0): an
`HttpTransport` such as `HttpClientTransport(http.Client())` from `fespalier_http`, or `DioTransport(dio)` from
`fespalier_dio`. Build it once, without the session on it.

## OpenID Connect and Keycloak

`OidcBackend` (`package:fespalier_oidc`) is the authorization code flow with PKCE (S256) for a **public** client, in
pure Dart over an `HttpTransport`: it owns the token exchange and the renewal, which is what makes single-flight
renewal, refresh-token rotation and DPoP on the token endpoint possible. Its `BearerAuthenticator` sends
`Authorization: Bearer <token>` and answers a 401 with `Renew`. The browser step is a function **you** give it, so the
package links no plugin: `flutter_web_auth_2` (MIT; Android, iOS, macOS, web, Windows, Linux) is the usual one. It signs
in with `BrowserSignIn` only; any other request throws `UnsupportedError`
(`fespalier_oidc: OidcBackend signs in with BrowserSignIn, not ...`).

```yaml
# pubspec.yaml dependencies
  flutter_web_auth_2: ^5.1.0
  http: ^1.2.0 # the transport's client; the Firebase and Supabase recipes below use it too
```

```dart
// lib/auth_setup.dart
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

final transport = HttpClientTransport(http.Client());

final issuer = Uri.parse('https://sso.example.com/realms/shop');

/// The browser step: Keycloak's login page in a Custom Tab, an ASWebAuthenticationSession or a
/// popup, and the redirect back. `preferEphemeral` keeps the browser's SSO cookie out of it.
Future<Uri> openBrowser(Uri url, Uri redirect) async {
  try {
    return Uri.parse(
      await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: redirect.scheme,
        options: const FlutterWebAuth2Options(preferEphemeral: true),
      ),
    );
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') throw const AuthCancelled();
    rethrow;
  }
}

AuthConfig authSetup() => AuthConfig(
  transport: transport,
  backend: OidcBackend(
    issuer: issuer,
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    // No discovery request: Keycloak's endpoints from the realm's issuer.
    endpoints: OidcEndpoints.keycloak(issuer),
    openBrowser: openBrowser,
    // The token, discovery and revocation calls. The same transport as AuthConfig's: it has no
    // session on it, and a session on the call that renews the session would wait for itself.
    transport: transport,
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

```dart
// lib/app/sign-in/page.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:flutter/material.dart';

class SignInPage extends ConsumerWidget {
  const SignInPage({super.key, this.from});

  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: FilledButton(
        // Straight from onPressed: a web popup is blocked when signIn is called later.
        onPressed: () => unawaited(_signIn(ref)),
        child: const Text('Sign in with Keycloak'),
      ),
    ),
  );

  Future<void> _signIn(WidgetRef ref) async {
    try {
      await ref.read(authSession.notifier).signIn(const BrowserSignIn());
    } on AuthCancelled {
      // The user closed the browser: nothing to say. The sign-in guard moves the user on success.
    }
  }
}
```

- **What it checks.** The redirect's `state` (`the redirect's state does not match the sign-in that opened it`), its
  `error` (`access_denied` is `AuthCancelled`; anything else is `OidcException`), its `iss` when present (RFC 9207: Keycloak sends
  it), its `code`; then the ID token's `iss`, `aud` and `nonce`. The ID token's signature is **not** verified
  (OpenID Connect Core 3.1.3.7: it came straight from the token endpoint over TLS). Messages and fixes:
  [`fespalier-troubleshooting`](../../fespalier-troubleshooting/SKILL.md), its `diagnostics-auth.md` page.
- **`BrowserSignIn`**: `loginHint`, `prompt` (`login` shows the form over an SSO cookie, `none` fails with
  `login_required` instead), and `parameters` (`{'kc_idp_hint': 'google', 'ui_locales': 'fr'}`).
- **No timeout of its own** (a timer): give it a transport over a client that times out, if you want one. A confidential
  client (`client_secret`) is out of scope: a mobile or web app is public. The session is a `TokenCredential` (access,
  refresh and ID token, `expiresAt`, `renewableUntil`, `jkt`; it was `AuthTokens` until 0.20.0), and
  `OidcBackend(renewAhead:)` is how early before `expiresAt` a token is renewed (30 seconds, what `AuthConfig.leeway` was).
- **Roles** come from the access token (`keycloakRoles(clientId)`, the default): `realm_access.roles` and
  `resource_access.<clientId>.roles`. Keycloak does not put them in the ID token unless a mapper does.
- **Sign-out** revokes the refresh token (RFC 7009), which makes Keycloak end the whole session
  (`signOut`, best effort). `endBrowserSession(session)` also ends the browser's SSO session through
  Keycloak's end-session endpoint (`id_token_hint`, `client_id`, `post_logout_redirect_uri`, which the client must list);
  with `preferEphemeral: true` there is none to end.

### What was read from a live Keycloak (26.8.0)

`examples/auth/keycloak/realm-fespalier.json` is a realm exported from one; `packages/fespalier_oidc/test/keycloak_live_test.dart`
runs `OidcBackend` against it. The settings that matter:

- A **public client**, Standard flow on, Direct access grants off, `pkce.code.challenge.method` `S256` (the client attribute: without
  PKCE the authorization endpoint answers `error=invalid_request&error_description=Missing+parameter%3A+code_challenge_method`).
  **Valid redirect URIs** must list `redirectUri` exactly; a custom scheme needs the whole `com.example.shop:/callback`.
- **"Revoke Refresh Token"** (`revokeRefreshToken`) makes a refresh token good **once**: a second renewal with the same one answers
  `invalid_grant` / `Maximum allowed refresh token reuse exceeded`, **and then the whole session is gone** (the rotated token answers
  `Session doesn't have required client`). That is why the renewal is a single flight, and why two isolates or two web tabs sharing
  one session sign each other out.
- **The refresh token's lifetime is the SSO idle timeout** (30 minutes by default; `refresh_expires_in` says): a user who is away
  longer gets `invalid_grant` / `Token is not active` (the same text after the SSO max lifespan). For longer sessions ask for the
  `offline_access` scope (`OidcBackend(scopes: ['openid', 'profile', 'email', 'offline_access'])`); its refresh token's `refresh_expires_in`
  is the offline idle timeout (30 days here), and `0` means it never expires.
- **The issuer is Keycloak's configured hostname.** With `--hostname=http://10.0.2.2:8080` the discovery document and every token say
  `http://10.0.2.2:8080/realms/...`; an app that reaches the same Keycloak as `localhost` gets `the ID token was issued by ..., not ...`.
  On an Android emulator use `adb reverse tcp:8080 tcp:8080` and `localhost`, or give Keycloak the `10.0.2.2` hostname.
- **A single-sign-on cookie signs the user in again silently** after a sign-out, unless the browser session is ephemeral
  (`preferEphemeral: true`) or the sign-in asks `BrowserSignIn(prompt: 'login')`.
- **Descriptions** of `invalid_grant` as Keycloak 26.8.0 words them: `Code not valid` (a code used twice: it also ends the session it made),
  `PKCE verification failed: Code mismatch`, `PKCE code verifier not specified`, `Incorrect redirect_uri`, `Invalid refresh token`,
  `Maximum allowed refresh token reuse exceeded`, `Session doesn't have required client`, `Session not active` (after a revocation or a
  logout), `Token is not active` (an expired refresh token). An unknown client is HTTP 401 `invalid_client` / `Invalid client or Invalid
client credentials`. A renewal's `AuthRejected` carries the `error` and this description.
- **Discovery** (`OidcEndpoints.discover(issuer)`, or leave `endpoints` out for a lazy one) says `dpop_signing_alg_values_supported`,
  `authorization_response_iss_parameter_supported` and the same endpoints `OidcEndpoints.keycloak` spells.

Run it: `docker run --rm -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin -v "$PWD/examples/auth/keycloak:/opt/keycloak/data/import:ro" quay.io/keycloak/keycloak:26.8.0 start-dev --import-realm`.

## Your own API (username and password)

The starter in [`auth-package.md`](auth-package.md) is the recipe, compiled: a credential (`ApiCredential`), what adds it to a
request (`ApiAuthenticator`) and the backend (`ApiBackend`) over `POST /auth/login`, `/auth/renew` and `/auth/logout`. A wrong
password is a `FieldErrors` (the form shows it under its field), the server refusing the refresh token is `AuthRejected`, and
anything else (a `TransportFailure`, a 5xx as a `TransportStatusError`) keeps the session. `examples/auth/lib/demo/demo_backend.dart`
is the same backend with a test server.

## Firebase Authentication

Firebase's SDK keeps the session and renews it itself (its own native timers: the SDK's, not the framework's), so the backend
says `keepsOwnSession`: the `TokenStore` is not used, `currentSession()` is read once at start-up, and `renew` asks the SDK for a
new ID token. Initialise Firebase in `startup()` before `restoreAuth`. The ID token is a bearer token, so the three pieces of
a token session come from `fespalier_oidc` (pure Dart): `TokenCredential`, `BearerAuthenticator` and `userFromClaims`. No
OpenID Connect flow runs; the SDK signs in.

```yaml
# pubspec.yaml dependencies
  firebase_auth: ^6.7.0
  firebase_core: ^4.14.0
```

```dart
// lib/firebase_backend.dart
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';

final class FirebaseBackend extends AuthBackend {
  FirebaseBackend([fb.FirebaseAuth? auth]) : _auth = auth ?? fb.FirebaseAuth.instance;

  final fb.FirebaseAuth _auth;

  @override
  String get name => 'firebase';

  @override
  String get scheme => 'bearer';

  @override
  bool get keepsOwnSession => true;

  @override
  BearerAuthenticator get authenticator => const BearerAuthenticator();

  /// Renew an ID token a minute before it runs out: the SDK's tokens last an hour.
  @override
  Duration get renewAhead => const Duration(minutes: 1);

  @override
  TokenCredential readCredential(Map<String, Object?> json) => TokenCredential.fromJson(json);

  /// One read of the first state the SDK reports: the framework keeps no listener.
  @override
  Future<AuthSession?> currentSession() async {
    final user = await _auth.authStateChanges().first;
    return user == null ? null : _session(user);
  }

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! PasswordSignIn) {
      throw UnsupportedError('FirebaseBackend signs in with PasswordSignIn');
    }
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: request.username,
        password: request.password,
      );
      return await _session(credential.user!);
    } on fb.FirebaseAuthException catch (e) {
      if (const {'wrong-password', 'invalid-credential', 'user-not-found'}.contains(e.code)) {
        throw const FieldErrors({'password': 'Wrong e-mail or password'});
      }
      rethrow;
    }
  }

  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) async {
    final user = _auth.currentUser;
    if (user == null) throw const AuthRejected('user-not-found');
    try {
      return await _session(user, forceRefresh: true);
    } on fb.FirebaseAuthException catch (e) {
      if (const {'user-disabled', 'user-token-expired', 'user-not-found'}.contains(e.code)) {
        throw AuthRejected(e.code);
      }
      rethrow;
    }
  }

  @override
  Future<void> signOut(AuthSession session) => _auth.signOut();

  Future<AuthSession> _session(fb.User user, {bool forceRefresh = false}) async {
    final result = await user.getIdTokenResult(forceRefresh);
    final claims = <String, Object?>{...?result.claims, 'sub': user.uid};
    return AuthSession(
      backend: name,
      credential: TokenCredential(accessToken: result.token!, expiresAt: result.expirationTime),
      user: userFromClaims(
        {...claims, 'email': user.email, 'name': user.displayName},
        roles: {if (claims['admin'] == true) 'admin'},
      ),
    );
  }
}
```

```dart
// lib/app/startup.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;
import 'package:my_app/firebase_backend.dart';

Future<List<Override>> startup() async {
  await Firebase.initializeApp();
  return restoreAuth(AuthConfig(
    backend: FirebaseBackend(),
    transport: HttpClientTransport(http.Client()),
    apiOrigins: [Uri.parse('https://api.example.com')],
  ));
}
```

- Firebase has no Linux. The ID token is a JWT the API verifies; `TokenCredential.expiresAt` comes from `expirationTime`.
- `restoreAuth` waits for the SDK's first auth state (`authStateChanges().first`), so `startup()` is async here: `splash.dart` shows.
- Until 0.20.0 this was `refresh`, `AuthTokens` and `AuthUser.fromClaims`, and `AuthConfig` had no `transport:`.

## Supabase

`supabase_flutter`'s client **auto-refreshes with a timer by default**. Turn it off (`autoRefreshToken: false`, documented in its
testing README), and renew lazily with `refreshSession()`: the single flight is then fespalier_auth's. Import it with a prefix:
`gotrue` exports `AuthState`, `Session`, `User` and `AuthException`. As for Firebase, the credential is a `TokenCredential`
and the authenticator a `BearerAuthenticator`.

```yaml
# pubspec.yaml dependencies
  supabase_flutter: ^2.18.0
```

```dart
// lib/supabase_backend.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

final class SupabaseBackend extends AuthBackend {
  SupabaseBackend(this.auth);

  final sb.GoTrueClient auth;

  @override
  String get name => 'supabase';

  @override
  String get scheme => 'bearer';

  @override
  bool get keepsOwnSession => true;

  @override
  BearerAuthenticator get authenticator => const BearerAuthenticator();

  @override
  Duration get renewAhead => const Duration(seconds: 30);

  @override
  TokenCredential readCredential(Map<String, Object?> json) => TokenCredential.fromJson(json);

  /// Synchronous: the SDK has loaded its session by the time `initialize` returned.
  @override
  AuthSession? currentSession() {
    final session = auth.currentSession;
    return session == null ? null : _session(session);
  }

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! PasswordSignIn) {
      throw UnsupportedError('SupabaseBackend signs in with PasswordSignIn');
    }
    try {
      final response = await auth.signInWithPassword(
        email: request.username,
        password: request.password,
      );
      return _session(response.session!);
    } on sb.AuthException catch (e) {
      if (e.message == 'Invalid login credentials') {
        throw const FieldErrors({'password': 'Wrong e-mail or password'});
      }
      rethrow;
    }
  }

  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) async {
    try {
      final response = await auth.refreshSession();
      return _session(response.session!);
    } on sb.AuthException catch (e) {
      if (e.statusCode == '400') throw const AuthRejected();
      rethrow;
    }
  }

  @override
  Future<void> signOut(AuthSession session) => auth.signOut();

  AuthSession _session(sb.Session session) => AuthSession(
    backend: name,
    credential: TokenCredential(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresAt: session.expiresAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(session.expiresAt! * 1000, isUtc: true),
    ),
    user: AuthUser(
      id: session.user.id,
      email: session.user.email,
      claims: {...session.user.appMetadata},
    ),
  );
}
```

```dart
// lib/supabase_startup.dart
import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:http/http.dart' as http;
import 'package:my_app/supabase_backend.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// Return this from lib/app/startup.dart's startup().
Future<List<Override>> startupWithSupabase() async {
  await sb.Supabase.initialize(
    url: 'https://example.supabase.co',
    publishableKey: 'public-key',
    // The SDK's own refresh timer off: fespalier_auth renews lazily, once.
    authOptions: const sb.FlutterAuthClientOptions(autoRefreshToken: false),
  );
  return restoreAuth(AuthConfig(
    backend: SupabaseBackend(sb.Supabase.instance.client.auth),
    transport: HttpClientTransport(http.Client()),
    apiOrigins: [Uri.parse('https://example.supabase.co')],
  ));
}
```

- The key is `publishableKey:` on 2.18.0 (`anonKey:` is deprecated there, and older releases only have it). Its value is public: it is not a secret.

## Dio

Dio is a transport implementation, not a special case. `fespalier_dio` has two bridges
([`docs/transport.md`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#the-two-implementations)):

- `DioTransport(dio)` is an `HttpTransport` over a Dio: use it as `AuthConfig.transport` (and `OidcBackend(transport:)`) when
  the app's network is Dio.
- `TransportAdapter(transport)` is Dio's `HttpClientAdapter` over a transport: `dio.httpClientAdapter =
TransportAdapter(ref.watch(authTransport))` puts the session under a Dio and its interceptors. A request to another origin
  is untouched. A body Dio finalizes (JSON, a form, a multipart `FormData`) becomes bytes, so it is sent again whole; a `Stream`
  as `data` stays a stream, is sent once, and its caller gets the 401, after the renewal. A renewal that could not run is a
  `DioException` whose `error` is the `AuthUnavailable`.

`SessionInterceptor` (`package:fespalier_auth/dio.dart`) and `DioHttpClient` (`package:fespalier_dio/client.dart`) existed until
0.20.0; `fespalier_auth` no longer depends on Dio at all.

## The request layer: replays, aborts and retries

- **A replay is marked.** The single replay after a verdict (a 401 renewal, a DPoP challenge) carries `transportReplayKey`
  (`'fespalier.auth.replay'`) in `TransportRequest.attributes`. A guard that refuses re-sends of writes lets that one through. The
  first send is not a replay. (It was `isAuthReplay(request)` and `options.extra[authReplayKey]` until 0.20.0.)
- **A replay keeps its abort trigger**: `TransportRequest.abortTrigger` is the request's, so aborting still cancels the replay when
  the page that wanted it goes away.
- **Do not put a retrier under the session.** A retrier under a signing session sends the same headers again, so with DPoP it
  re-sends the **same proof**, and the server refuses a reused `jti`: Keycloak answers `invalid_request` / `DPoP proof has already
been used`. Put it above: `dio_smart_retry` on a Dio whose adapter is `TransportAdapter(ref.watch(authTransport))`, or a
  `RetryClient` over `TransportClient(ref.watch(authTransport))`. Every attempt then asks the session for a proof of its own. A
  Dio retrier reuses `RequestOptions.extra`, so the request's `TransportMemo` keeps the session's decisions across attempts; a
  `RetryClient` sends a **copy** of each request (as a stream), so each copy is a new logical request for the memo, and a
  scheme that signs the body (`fespalier_sign_keypair`) cannot sign a streamed one: retry reads with it, writes in Dio.
