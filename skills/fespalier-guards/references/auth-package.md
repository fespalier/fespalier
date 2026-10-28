# `fespalier_auth`: signed-in routes

Since 0.9.0. fespalier's core has no auth feature; `package:fespalier_auth` is the pattern of
[`auth-patterns.md`](auth-patterns.md) packaged: a session provider, `restoreAuth` for `startup()`, session
storage, lazy single-flight renewal, the guard helpers and a transport that carries the session, behind one
`AuthBackend`. It changes **no** generated code, adds no file kind, no `fespalier:` key and no `fsp`
command: an app that does not import it is byte-for-byte what it was.

**Since 0.21.0 the package is the protocol-agnostic core.** It knows a `SessionCredential`, a `RequestAuthenticator`
and an `AuthBackend`, and no token, no OpenID Connect flow and no key; what proves a session to your API is a
**backend** you add next to it (`fespalier_oidc`, `fespalier_sign_keypair`, or one of your own), and what sends is an
`HttpTransport` ([`fespalier_transport`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md)) you give
`AuthConfig`. Until 0.20.0 the package held the token flow and a `package:http` client; the old names are in
`fespalier-migration`.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: <the same tag>
  fespalier_http: # a transport implementation (or fespalier_dio, for Dio)
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_http
      ref: <the same tag>
```

(That block is a fragment, not a sample: pub resolves the packages only at a release tag. Add `fespalier_oidc` or
`fespalier_sign_keypair` the same way when you use them. `fespalier_transport` comes with them.) A mismatch fails with
pub's own `Because every version of fespalier_auth from path depends on fespalier from git ... at v0.7.0 ...
and demo depends on fespalier from git ... at v0.6.0 ..., fespalier_auth from path is forbidden.` Give every
dependency the same `url` (no `.git`) and the same `ref`.

## What it is made of

| Piece                                             | What it does                                                                                                                                                                                                                                                                  |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `authSession`                                     | The session: a `NotifierProvider<AuthSessionNotifier, SessionState>`. `SessionState` is sealed: `SessionRestoring`, `SignedOut(reason)`, `SignedIn(session)`. The notifier has `signIn`, `adopt`, `signOut`, `endSession(reason)`, `credential()` and `stepUp` (since 0.25.0) |
| `isSignedIn`, `authUser`, `authUserId`            | Derived providers. Riverpod filters updates with `==`, so none of them notifies on a renewal                                                                                                                                                                                  |
| `restoreAuth(config)`                             | For `startup()`: reads the stored session and returns the overrides. Synchronous with a synchronous store, and **never** touches the network                                                                                                                                  |
| `AuthConfig`                                      | `backend`, **`transport`** (required: what requests, and the backend's own calls, go through), `store` (`SecureTokenStore` by default, `MemoryTokenStore`) and `apiOrigins`. `leeway` is gone: when a credential counts as expired is `AuthBackend.renewAhead`                |
| `AuthBackend`                                     | `name`, `scheme`, `authenticator`, `readCredential`, `renewAhead`, `signIn`, `renew` (was `refresh` until 0.20.0), `check`, `signOut`, `discard`; `keepsOwnSession` and `currentSession()` for Firebase and Supabase. Sign-in requests are typed (`SignInRequest`)            |
| `SessionCredential`, `RequestAuthenticator`       | What proves a session (`expiresAt`, `renewableUntil`, `renewable`, `toJson`), and what adds it to each send (`headers`) and reads each answer (`judge` returns an `AuthVerdict`: `Accept`, `Resend`, `Renew`, `StepUp` since 0.25.0, `SessionEnded`)                          |
| `requireSignedIn`, `requireRole`, `requireUser`   | For a `guard.dart`: null, or the sign-in location with the requested one as `from`                                                                                                                                                                                            |
| `redirectIfSignedIn`                              | For the **sign-in route's own** `guard.dart`: signing in sends the user back by itself                                                                                                                                                                                        |
| `requireFreshAuth`, `redirectIfFreshAuth`         | Since 0.25.0: a route that needs a sign-in younger than `maxAge`, and the re-proof page's own guard. See [Step-up and recent sign-ins](#step-up-and-recent-sign-ins)                                                                                                          |
| `StepUpChallenge`, `parseChallenges`              | Since 0.25.0: what an RFC 9470 refusal asks (`acrValues`, `maxAge`; `StepUpChallenge.fromResponse`), and a `WWW-Authenticate` parser (`HttpChallenge`)                                                                                                                        |
| `authTransport`, `SessionTransport`, `Authorizer` | An `HttpTransport` whose requests to `apiOrigins` carry the session, renew once on expiry and are sent again after a verdict that says so. `Authorizer` is an `HttpCredentials`, for a client that is not a transport                                                         |
| `package:fespalier_oidc`                          | `OidcBackend`, `BearerAuthenticator`, `TokenCredential`, `BrowserSignIn`, `PasswordSignIn`: OpenID Connect and Keycloak, bearer tokens. A separate package since 0.21.0. See [`auth-backends.md`](auth-backends.md)                                                           |
| `package:fespalier_keypair_dpop`                  | `DpopProof`: DPoP proofs for `OidcBackend(proof: ...)`, on a key from `fespalier_keypair`. See [`auth-dpop.md`](auth-dpop.md)                                                                                                                                                 |
| `package:fespalier_sign_keypair`                  | `DeviceAuthBackend`: a session with no token, proved by a signature from the device key over each request (since 0.21.0). See [`auth-device-sessions.md`](auth-device-sessions.md)                                                                                            |
| `package:fespalier_auth/testing.dart`             | `FakeAuthBackend`, `FakeCredential`, `FakeAuthenticator`, `fakeSession`, `fakeAuth`                                                                                                                                                                                           |

Signing in with **OpenID Connect or Keycloak, Firebase, Supabase, or your own API** is
[`auth-backends.md`](auth-backends.md), binding the tokens to the device (DPoP) is [`auth-dpop.md`](auth-dpop.md), a
session with no token at all is [`auth-device-sessions.md`](auth-device-sessions.md); this page is the package and a
starter over a JSON API. `examples/auth` runs all of it with an in-process demo API and tests, and has a Keycloak realm.

## The starter

Five files and a backend. `sign-in/` sits **beside** `(signed-in)/`: a guard on the sign-in page would send the user to
the sign-in page. The backend is complete: a credential (an access token and a refresh token), what adds it to a request
(`ApiAuthenticator`) and the backend that makes, renews and ends sessions over `POST /auth/login`, `/auth/renew` and
`/auth/logout`. `PasswordSignIn` is a plain carrier for a user name and a password that lives in `fespalier_oidc`
(pure Dart, no plugin); an app that would rather not depend on that package for it writes a `SignInRequest` of its own.
If your tokens are standard, `TokenCredential` and `BearerAuthenticator` from `fespalier_oidc` already are the first two
classes.

```yaml
# pubspec.yaml dependencies
  clock: ^1.1.1
  http: ^1.2.0
```

```dart
// lib/auth_setup.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart' show PasswordSignIn;
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;

/// What proves a session to the API: two tokens and when the access token runs out. `toString`
/// shows no secret, and equality is by value (the core compares a credential a server refused
/// with the one the session holds now).
final class ApiCredential implements SessionCredential {
  const ApiCredential({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  /// Reads what [toJson] wrote; a `FormatException` drops the stored session at restore.
  factory ApiCredential.fromJson(Map<String, Object?> json) {
    final access = json['accessToken'];
    final refresh = json['refreshToken'];
    final expires = json['expiresAt'];
    if (access is! String || refresh is! String || expires is! String) {
      throw const FormatException('ApiCredential: a stored credential is malformed');
    }
    return ApiCredential(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.parse(expires),
    );
  }

  final String accessToken;
  final String refreshToken;

  @override
  final DateTime expiresAt;

  @override
  DateTime? get renewableUntil => null;

  @override
  bool get renewable => true;

  @override
  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is ApiCredential &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.expiresAt == expiresAt;

  @override
  int get hashCode => Object.hash(accessToken, refreshToken, expiresAt);

  @override
  String toString() => 'ApiCredential()';
}

/// What a send carries, and what a response means. Called for every send, with the exact body
/// bytes in `request.body`, so a scheme that signs signs what goes out.
final class ApiAuthenticator implements RequestAuthenticator {
  const ApiAuthenticator();

  @override
  Future<Map<String, String>> headers(AuthSession session, TransportRequest request) async {
    final credential = session.credential as ApiCredential;
    return {'Authorization': 'Bearer ${credential.accessToken}'};
  }

  /// A 401 says the access token was refused: renew, then send once more. Anything else stands,
  /// so a session is never wiped by an answer that may be about something else.
  @override
  AuthVerdict judge(
    AuthSession session,
    TransportRequest request, {
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  }) => statusCode == 401 ? const Renew() : const Accept();
}

/// Your own API: POST /auth/login, /auth/renew and /auth/logout, answering
/// {"access_token", "refresh_token", "expires_in", "user": {"id", "name", "roles"}}.
final class ApiBackend extends AuthBackend {
  const ApiBackend(this.base, this.transport);

  final Uri base;

  /// The app's transport, without the session: the login call must not wait for a session.
  final HttpTransport transport;

  @override
  String get name => 'api';

  @override
  ApiAuthenticator get authenticator => const ApiAuthenticator();

  /// Renew an access token this long before it runs out; a request that finds it so renews it.
  @override
  Duration get renewAhead => const Duration(seconds: 30);

  @override
  ApiCredential readCredential(Map<String, Object?> json) => ApiCredential.fromJson(json);

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! PasswordSignIn) {
      throw UnsupportedError('ApiBackend signs in with PasswordSignIn');
    }
    final answer = await _post('/auth/login', {
      'username': request.username,
      'password': request.password,
    });
    // A form shows this under the password field: nothing to catch in the page.
    if (answer.status == 401) {
      throw const FieldErrors({'password': 'Wrong user name or password'});
    }
    return _session(answer);
  }

  /// The server refused the refresh token: the session is over (`AuthRejected`). Anything else
  /// thrown here (a TransportFailure, a 503) keeps the session and is tried again.
  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) async {
    final credential = session.credential as ApiCredential;
    final answer = await _post('/auth/renew', {'refresh_token': credential.refreshToken});
    if (answer.status == 400 || answer.status == 401) throw const AuthRejected();
    return _session(answer, previous: session);
  }

  /// Best effort: the local sign-out has already happened.
  @override
  Future<void> signOut(AuthSession session) async {
    final credential = session.credential as ApiCredential;
    await _post('/auth/logout', {'refresh_token': credential.refreshToken});
  }

  Future<({int status, String body})> _post(String path, Map<String, Object?> json) async {
    final response = await transport.send(
      TransportRequest(
        method: 'POST',
        uri: base.resolve(path),
        headers: const {'content-type': 'application/json'},
        body: Uint8List.fromList(utf8.encode(jsonEncode(json))),
      ),
    );
    final bytes = await response.bytes();
    if (response.statusCode >= 500) {
      throw TransportStatusError(
        statusCode: response.statusCode,
        headers: response.headers,
        body: bytes,
      );
    }
    return (status: response.statusCode, body: utf8.decode(bytes));
  }

  AuthSession _session(({int status, String body}) answer, {AuthSession? previous}) {
    final json = jsonDecode(answer.body) as Map<String, Object?>;
    final user = json['user'] as Map<String, Object?>?;
    return AuthSession(
      backend: name,
      credential: ApiCredential(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
        // clock.now(), not DateTime.now(): a test's fake clock ages the token.
        expiresAt: clock.now().add(Duration(seconds: json['expires_in'] as int)),
      ),
      user: user == null
          ? previous!.user
          : AuthUser(
              id: user['id'] as String,
              name: user['name'] as String?,
              roles: {...?(user['roles'] as List<Object?>?)?.cast<String>()},
            ),
    );
  }
}

/// One transport, built once: no session on it. `authTransport` wraps it in the session.
final HttpTransport transport = HttpClientTransport(http.Client());

AuthConfig authSetup() => AuthConfig(
  backend: ApiBackend(Uri.parse('https://api.example.com'), transport),
  transport: transport,
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

```dart
// lib/app/startup.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:my_app/auth_setup.dart';

/// Reads the stored session before the first frame. A keychain read is async, so
/// splash.dart shows meanwhile; with a MemoryTokenStore there is no frame to wait for.
FutureOr<List<Override>> startup() => restoreAuth(authSetup());
```

```dart
// lib/app/(signed-in)/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:my_app/app.g.dart';

/// Guards everything in the group. Synchronous: no frame, and a cold deep link shows its page.
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));
```

```dart
// lib/app/sign-in/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// The trap: without this guard, signing in changes the session and nothing moves. It watches
/// the session, so the sign-in page goes back to `from` (or `/`) as soon as there is one.
GuardResult guard(Ref ref, {String? from}) => redirectIfSignedIn(ref, from: from);
```

The sign-in page is a form, so the app also lists `fespalier_forms` (since 0.11.0) under `dependencies:`, at the same
`url` and `ref` ([`fespalier-data`](../../fespalier-data/references/forms.md)).

```dart
// lib/app/sign-in/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart' show PasswordSignIn;

typedef SignInFields = ({String username, String password});

SignInFields form() => (username: '', password: '');

FieldErrors? validate(SignInFields input) => FieldErrors({
  if (input.username.trim().isEmpty) 'username': 'Enter your user name',
  if (input.password.isEmpty) 'password': 'Enter your password',
});

/// A wrong password is the backend's FieldErrors, which the form shows under its field.
Future<void> action(Ref ref, {required SignInFields input}) async {
  await ref
      .read(authSession.notifier)
      .signIn(PasswordSignIn(username: input.username.trim(), password: input.password));
}
```

```dart
// lib/app/sign-in/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class SignInPage extends HookConsumerWidget {
  const SignInPage({super.key, this.from});

  /// Where the guard that sent us here was going: the sign-in guard uses it.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final form = SignInRoute.useForm(ref);
    final fields = form.fields;
    final expired = ref.watch(
      authSession.select((s) => s is SignedOut && s.reason == SignOutReason.expired),
    );
    return Scaffold(
      body: Column(
        children: [
          if (expired) const Text('Your session expired. Sign in again.'),
          TextField(
            controller: fields.username.controller,
            decoration: InputDecoration(labelText: 'User name', errorText: fields.username.error),
          ),
          TextField(
            controller: fields.password.controller,
            obscureText: true,
            decoration: InputDecoration(labelText: 'Password', errorText: fields.password.error),
          ),
          if (form.error case final error?) Text('$error'),
          // Null while the sign-in runs: the button is disabled. No navigation code: the
          // sign-in guard moves the user.
          FilledButton(
            onPressed: form.onSubmit,
            child: Text(form.isPending ? 'Signing in...' : 'Sign in'),
          ),
        ],
      ),
    );
  }
}
```

```dart
// lib/app/(signed-in)/orders/data.dart
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';

Future<List<String>> data(Ref ref) async {
  // Another user loads this again; a renewal does not.
  ref.watch(authUserId);
  // An http.Client over the session: the request carries it, renewed once if it has expired.
  final client = TransportClient(ref.watch(authTransport));
  final response = await client.get(Uri.parse('https://api.example.com/orders'));
  if (response.statusCode != 200) {
    throw StateError('orders: HTTP ${response.statusCode}');
  }
  return (jsonDecode(response.body) as List<Object?>).cast<String>();
}
```

```dart
// lib/app/(signed-in)/orders/page.dart
import 'package:flutter/material.dart';

class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key, required this.orders});

  final List<String> orders;

  @override
  Widget build(BuildContext context) => Column(children: [for (final o in orders) Text(o)]);
}
```

## Step-up and recent sign-ins

Since 0.25.0. An API that accepts the session may still refuse one request because the sign-in is too weak or too old
for it ([RFC 9470](https://www.rfc-editor.org/rfc/rfc9470)): a `401` with
`WWW-Authenticate: Bearer error="insufficient_user_authentication", acr_values="gold", max_age=300` (both parameters
optional; a `DPoP` challenge counts too).

- **It is its own verdict, `StepUp(StepUpChallenge)`, not a `Renew`.** `fespalier_oidc`'s `BearerAuthenticator`
  answers it for that 401 (any other 401 is still `Renew`); `StepUpChallenge.fromResponse(status, headers)` reads
  `acrValues` and `maxAge` for an authenticator of your own, over `parseChallenges` (case-insensitive schemes, quoted and
  token parameters, several challenges in one header or joined headers).
- **The session asks the user once, then sends the request once more.** `AuthSessionNotifier.stepUp(challenge)` runs
  `AuthBackend.stepUp(session, challenge)`, one at a time (every request refused meanwhile waits for it; one refused
  after another request stepped up retries with the new credential without asking), stores the new session and
  publishes it. `OidcBackend.stepUp` is the browser sign-in again with `acr_values` / `max_age`, or `prompt=login` when
  the challenge names neither, and `login_hint` = the user's e-mail.
- **At most one step-up per logical request** (kept in its `TransportMemo`, like the renewal): a second refusal is the
  401 the caller gets, never a loop. A request can renew once and step up once.
- **A refused or cancelled step-up keeps the session.** `AuthCancelled` (the user closed the browser, `access_denied`)
  and `AuthRejected` (the provider refused) leave `SignedIn` as it was and the request's 401 stands; it is not a
  renewal, whose refusal signs out. A step-up that could not run is `AuthUnavailable`. One that comes back as another
  user is `AuthRejected('step_up_user_mismatch')` and that session is not taken.
- **Background work never prompts.** Mark it `Authorizer.stepUpAttribute: false` (`TransportRequest.attributes`, or
  Dio's `Options(extra: ...)`): its 401 stands.
- **`AuthBackend.stepUp`'s default throws `UnsupportedError`.** `DeviceAuthBackend` has none: a device session signs a
  call that needs the user with the user-present key from the start ([`auth-device-sessions.md`](auth-device-sessions.md)),
  never after a refusal.
- **`AuthSession.authenticatedAt`** is when the user last proved who they are: the ID token's `auth_time`, else the time
  of `signIn`, `adopt` or `stepUp` (`clock.now()`); a renewal keeps it. It is stored as an optional key of the same
  version-2 session, so a session stored before 0.25.0 restores with `null`, which the freshness guards read as too old.

A route that needs a recent sign-in, and the re-proof page that sends the user back:

```dart
// lib/app/(signed-in)/payouts/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:my_app/app.g.dart';

/// Read when the route opens (no timer): a page open longer than five minutes stays open.
GuardResult guard(Ref ref, {required Uri uri}) => requireFreshAuth(
  ref,
  uri,
  maxAge: const Duration(minutes: 5),
  signIn: (from) => SignInRoute(from: from),
  reauthenticate: (from) => ReauthRoute(from: from),
);
```

```dart
// lib/app/(signed-in)/payouts/page.dart
import 'package:flutter/material.dart';

class PayoutsPage extends StatelessWidget {
  const PayoutsPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('Payouts');
}
```

```dart
// lib/app/(signed-in)/reauth/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// The same maxAge: a step-up on the page sends the user back to `from` by itself.
GuardResult guard(Ref ref, {String? from}) =>
    redirectIfFreshAuth(ref, maxAge: const Duration(minutes: 5), from: from);
```

```dart
// lib/app/(signed-in)/reauth/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';

class ReauthPage extends HookConsumerWidget {
  const ReauthPage({super.key, this.from});

  /// Where requireFreshAuth was going: the page's guard uses it.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton(
    // On a tap only. No navigation code: redirectIfFreshAuth moves the user.
    onPressed: () async {
      try {
        await ref
            .read(authSession.notifier)
            .stepUp(const StepUpChallenge(maxAge: Duration(minutes: 5)));
      } on AuthCancelled {
        // The user closed the browser: stay here.
      } on AuthRejected {
        // The provider refused: stay here.
      }
    },
    child: const Text('Confirm it is you'),
  );
}
```

In a test, `fakeAuth(signedInAs: ada, authenticatedAt: clock.now())` opens a fresh-only route (no `authenticatedAt`
is too old), `tester.pump(duration)` ages it, and `FakeAuthBackend` counts `stepUps`, records `stepUpChallenges`, fails
with `stepUpError` and answers as `stepUpUser`; `FakeAuthenticator` answers `StepUp` to a 401 that carries the
challenge. Telemetry: an `auth` span with the step `step_up`.

## Test it

```dart
// test/auth_test.dart
import 'dart:async';

import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart' show PasswordSignIn;
import 'package:fespalier_transport/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

final api = Uri.parse('https://api.example.com');

void main() {
  testWidgets('signed out, a guarded page asks for sign-in and remembers where', (tester) async {
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/orders'), overrides: fakeAuth());
    expect(currentLocation(tester), '/sign-in?from=%2Forders');
  });

  testWidgets('signed in, the page loads its data with the session', (tester) async {
    String? sent;
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders'),
      overrides: fakeAuth(
        signedInAs: const AuthUser(id: 'ada'),
        apiOrigins: [api],
        // A FakeTransport answers from a handler and records what it was sent.
        transport: FakeTransport((request, body) {
          sent = request.headers['x-fake-credential'];
          return fakeResponse(200, body: '["order 1", "order 2"]');
        }),
      ),
    );
    expect(currentLocation(tester), '/orders');
    expect(find.text('order 2'), findsOneWidget);
    // FakeAuth's authenticator signs the credential `fake-0`, send number 1.
    expect(sent, 'fake-0#1');
  });

  testWidgets('signing in sends the user back, with no navigation code in the page', (tester) async {
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders'),
      overrides: fakeAuth(
        apiOrigins: [api],
        transport: FakeTransport((_, _) => fakeResponse(200, body: '["order 1"]')),
      ),
    );
    await container
        .read(authSession.notifier)
        .signIn(const PasswordSignIn(username: 'ada', password: 'ada'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/orders');
    expect(find.text('order 1'), findsOneWidget);
  });

  testWidgets('the button is disabled while the sign-in runs, then the user goes home', (tester) async {
    // The fake backend holds the call open on a Completer: a pending state to look at.
    final backend = FakeAuthBackend()..gate = Completer<void>();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: fakeAuth(backend: backend),
    );
    await tester.enterText(find.byType(TextField).first, 'ada');
    await tester.enterText(find.byType(TextField).last, 'secret');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Signing in...'), findsOneWidget);
    expect(backend.signIns, 1);
    backend.gate!.complete();
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
  });

  testWidgets('the form: empty fields are refused before the backend is asked', (tester) async {
    final backend = FakeAuthBackend();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: fakeAuth(backend: backend),
    );
    await tester.tap(find.text('Sign in').last);
    await tester.pumpAndSettle();
    expect(find.text('Enter your user name'), findsOneWidget);
    expect(backend.signIns, 0);
  });
}
```

## Behaviour to rely on

- **No `renewing` state.** A renewal keeps `SignedIn` and swaps the credential. A refusal of the renewal
  (`AuthRejected`, an OAuth `invalid_grant`) is `SignedOut(reason: SignOutReason.expired)`; a backend that throws
  `AuthEnded(reason)` gives another reason (`revoked`). A renewal that could not run (offline, a 5xx:
  `AuthUnavailable`) keeps the session and is tried again by the next request.
- **`credential()` is synchronous while the credential is good** (`expiresAt - AuthBackend.renewAhead` still ahead of
  `clock.now()`; was `tokens()` and `AuthConfig.leeway`, 30 s, until 0.20.0), and one shared renewal otherwise: any
  number of requests that find it expired wait for the same `Future`. That is what refresh-token rotation needs
  (Keycloak's "Revoke Refresh Token" refuses a second renewal with the same token). There is **no timer**: nothing
  renews in the background, and a test greps `lib/` for `Timer(`, `Future.delayed`, `.listen(` and `DateTime.now()`.
- **`restoreAuth` does no network.** An expired credential is renewed by the first request that needs it, so an
  offline start works. It drops a stored session of another backend (`AuthBackend.name` differs), one that cannot be
  renewed any more (`SignedOut(expired)`), and one the backend's `check` refuses: a device key that is gone is
  `SignedOut(keyLost)`.
- **A session stored by 0.20.0 or earlier is dropped (since 0.21.0).** The stored session is `{"v": 2, "backend",
"credential", "user"}`; a `"v": 1` one (tokens in it) throws a `FormatException` (`fespalier_auth: unknown stored
session version 1`) that `restoreAuth` reports (`FlutterError.reportError`, context `while restoring the stored
session`), deletes and answers `SignedOut()`: the user signs in once more. A widget test that restores a v1 session fails
  on the report until it calls `tester.takeException()`.
- **Without `restoreAuth`** in `startup()` the session restores itself at the first read: the state is
  `SessionRestoring` while an async store answers, and the guard helpers return a `Future` for that long
  (a blank first frame on a cold deep link). Read the store in `startup()` to avoid it.
- **A sign-out is synchronous**: `signOut()` sets `SignedOut(reason: SignOutReason.user)` before its first
  `await`, so guards move the user in that frame; then the
  store is cleared, the backend's `signOut` runs (its errors are swallowed) and its `discard` forgets what was
  bound to the session (a DPoP key, a device's keys). `endSession(reason)` (since 0.21.0) is the same without
  the server call, for an app whose own API says the device is revoked (`SignOutReason.revoked`). A button over
  a page that was **pushed** needs no navigation when that page is behind the guard (the guard of a pushed page
  watches while the page is on top, since 0.21.0, and a sign-out over a guarded base page replaces the whole stack);
  over a pushed page with no guard of its own, navigate too (`const HomeRoute().go(context)`): the guards under a
  pushed page react only once it is uncovered (see `auth-patterns.md`).
- **`apiOrigins` is an allow-list** (scheme, host and port). `SessionTransport` sends nothing to another host,
  so a credential cannot leak to a third party. An empty list is an error the first time `authorizer` is read:
  `fespalier_auth: AuthConfig.apiOrigins is empty, so no request would carry the session; list your API's origins, e.g. apiOrigins: [Uri.parse('https://api.example.com')]`.
- **`authTransport` is `SessionTransport(AuthConfig.transport, authorizer)`.** A client that is not a transport sits on
  top of it: `TransportClient(ref.watch(authTransport))` (`fespalier_http`) is an `http.Client`,
  `TransportAdapter(ref.watch(authTransport))` (`fespalier_dio`) a Dio adapter. Until 0.20.0 these were `authHttpClient`
  (and `authBaseClient`, `SessionClient`) and `package:fespalier_auth/dio.dart`'s `SessionInterceptor`.
- **What a response means is the authenticator's to say.** `judge` answers `Accept` (the response stands: anything
  ambiguous is this), `Resend` (same session, new headers: a DPoP nonce, a clock correction), `Renew` (renew, then send
  once more), `StepUp(challenge)` (since 0.25.0: the user proves who they are again, then send once more) or
  `SessionEnded(reason)` (sign out and fail the request with `AuthRejected`).
- **At most four sends per request** (three before 0.25.0): the first, one after a `Resend`, one after a `Renew` and one
  after a `StepUp`. **Every send is
  authorized again with the exact bytes of the body**, so a signature is fresh each time. A request whose body is a
  stream (`TransportRequest.replayable` false) is sent once, and its caller gets the 401, after the renewal, so its next
  attempt works.
- **The replay is marked, and keeps its abort trigger.** A send that followed a verdict carries
  `transportReplayKey` (`'fespalier.auth.replay'`) in `TransportRequest.attributes`, so a guard against re-sent writes
  (`WriteGuardTransport`, Dio's `WriteGuard`) lets that one through; the first send is not a replay. It was
  `isAuthReplay(request)` and `options.extra[authReplayKey]` until 0.20.0.
- **A request is never sent again without the session it had.** A retrier (`dio_smart_retry`, `RetryClient`) calls the
  session again for the same logical request, and the request's `TransportMemo` (`attributes['fespalier.memo']`)
  carries what the session settled the first time: a request it refused is refused again with the same `AuthRejected`
  (no renewal, no send); a request authorized for one user is never sent again as another or with nobody signed in; and
  a request renews at most once. A client that keeps no memo makes every send a first one: `TransportAdapter` and
  `TransportClient` keep one ([`docs/transport.md`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#the-memo)
  says where it breaks). `authRefusedKey` and `authWantedKey`, the `options.extra` marks of 0.19.0 to 0.20.0, are gone.
- **A retrier goes over the session, never under it.** Under a session that signs requests it would send the same
  signature again (with DPoP, the same proof, and the server refuses a reused `jti`: Keycloak `invalid_request`,
  `DPoP proof has already been used`; see `fespalier-troubleshooting`). Above it, every retry calls the session. The
  order of the whole chain is in `fespalier-observability` (`references/telemetry.md`) and
  [`docs/transport.md`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#decorators-and-their-order).
- **Credentials, ids and e-mails never reach a log, a telemetry attribute or an error text**: `TokenCredential`,
  `AuthUser`, `AuthSession` and `PasswordSignIn` print without them, and a `SessionCredential`'s `toString` shows no
  secret (yours must not either).
- **User data and persistence.** A `data.dart` whose data belongs to the user should
  `ref.watch(authUserId)`; a `dataCache` (since 0.8.1) keeps the previous user's data until it loads again, so
  clear the cache storage on sign-out.
- **With `fespalier_cratestack` (since 0.10.0), the account is `authUserId`.** Set
  `crateStackScope.overrideWith((ref) => ref.watch(authUserId))`: every intent, owned row and saved read is keyed by it, so
  one account's offline data never reaches another. **Wipe before the sign-out**: `await
ref.read(crateStackAccount).clear()` and then `ref.read(authSession.notifier).signOut()`. `signOut()` sets `SignedOut`
  before its first `await`, so `crateStackScope` is already `null` afterwards and a late `clear()` finds no account; after
  it, name the account you left, `clear(scope: leavingId)`. A queued call answered `401` keeps its idempotency key (the
  session is being renewed, and the renewal being lazy is why a server that namespaces keys by the
  `Authorization` header can run a call twice: `fespalier-cratestack`, `references/server-contract.md`).
- **One isolate.** The single flight is per `ProviderContainer`. A second isolate or a second web tab that
  renews the same rotating token gets `invalid_grant` and signs the user out: renew in one place, or do
  not turn rotation on.

## Testing

`fakeAuth(signedInAs: ..., backend: ..., store: ..., apiOrigins: ..., transport: ..., credentialLifetime: ...)` returns
the overrides for `pumpRouter`; call it **inside the test body**, where the fake clock starts, so
`tester.pump(const Duration(minutes: 6))` ages a session that has a `credentialLifetime`. The `transport:` is a
`FakeTransport` (`package:fespalier_transport/testing.dart`; it was `client:` with a `MockClient` until 0.20.0);
`fakeResponse(status, body: ...)` makes its answers. `FakeAuthBackend` counts `signIns`, `renewals`, `signOuts`
and `discards`, fails with `signInError` and `renewError` (`AuthRejected()` ends the session as `expired`,
`AuthEnded(SignOutReason.revoked)` as `revoked`, anything else keeps it), answers `check` with `checkResult`, and holds a
call open with `gate` (a `Completer<void>`): the way to see a pending state. Its credentials are numbered
`FakeCredential`s (`fake-1`, no secret), and its `FakeAuthenticator` adds `x-fake-credential: <id>#<n>` to every send
(`signed` has the requests), so a test sees that each send was authorized afresh. In `fsp test`'s `setup.dart`,
`List<Override> overrides(String pattern) => fakeAuth(signedInAs: ...)` makes every guarded route render.
`RecordingTelemetry` sees the `auth` spans (`#1 start auth renew backend=fake trigger=expired scheme=fake`).
