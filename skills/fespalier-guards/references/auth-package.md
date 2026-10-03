# `fespalier_auth`: signed-in routes

Since 0.9.0. fespalier's core has no auth feature; `package:fespalier_auth` is the pattern of
[`auth-patterns.md`](auth-patterns.md) packaged: a session provider, `restoreAuth` for `startup()`, token
storage, lazy single-flight refresh, the guard helpers and an authenticated HTTP client, behind one
`AuthBackend`. It changes **no** generated code, adds no file kind, no `fespalier:` key and no `fsp`
command: an app that does not import it is byte-for-byte what it was.

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
```

(That block is a fragment, not a sample: pub resolves the pair only at a release tag.) A mismatch fails with
pub's own `Because every version of fespalier_auth from path depends on fespalier from git ... at v0.7.0 ...
and demo depends on fespalier from git ... at v0.6.0 ..., fespalier_auth from path is forbidden.` Give both
dependencies the same `url` (no `.git`) and the same `ref`.

## What it is made of

| Piece                                           | What it does                                                                                                                                                                                       |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `authSession`                                   | The session: a `NotifierProvider<AuthSessionNotifier, SessionState>`. `SessionState` is sealed: `SessionRestoring`, `SignedOut(reason)`, `SignedIn(session)`                                       |
| `isSignedIn`, `authUser`, `authUserId`          | Derived providers. Riverpod filters updates with `==`, so none of them notifies on a token refresh                                                                                                 |
| `restoreAuth(config)`                           | For `startup()`: reads the stored session and returns the overrides. Synchronous with a synchronous store, and **never** touches the network                                                       |
| `AuthConfig`                                    | `backend`, `store` (`SecureTokenStore` by default, `MemoryTokenStore`), `apiOrigins` and `leeway` (30 s)                                                                                           |
| `AuthBackend`                                   | `signIn`, `refresh`, `signOut`, and `name`; `proof` for DPoP and `keepsOwnSession` for Firebase and Supabase. Sign-in requests are typed (`BrowserSignIn`, `PasswordSignIn`, or your own subclass) |
| `requireSignedIn`, `requireRole`, `requireUser` | For a `guard.dart`: null, or the sign-in location with the requested one as `from`                                                                                                                 |
| `redirectIfSignedIn`                            | For the **sign-in route's own** `guard.dart`: signing in sends the user back by itself                                                                                                             |
| `authHttpClient`, `SessionClient`, `Authorizer` | A `package:http` client whose requests to `apiOrigins` carry the session, refresh once on expiry, and are sent again once after a 401                                                              |
| `package:fespalier_auth/testing.dart`           | `FakeAuthBackend`, `FakeProof`, `fakeSession`, `fakeAuth`                                                                                                                                          |

## The starter

Five files and a backend (`clock` and `http` are the app's own dependencies here). `sign-in/` sits **beside**
`(signed-in)/`: a guard on the sign-in page would send the user to the sign-in page.

```yaml
# pubspec.yaml dependencies
  clock: ^1.1.1
  http: ^1.2.0
```

```dart
// lib/auth_setup.dart
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:http/http.dart' as http;

/// Your own API: POST /auth/login and POST /auth/refresh, answering
/// {"access_token", "refresh_token", "expires_in", "user": {"id", "name", "roles"}}.
final class ApiBackend extends AuthBackend {
  ApiBackend(this.base, {http.Client? client}) : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  @override
  String get name => 'api';

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! PasswordSignIn) {
      throw UnsupportedError('ApiBackend signs in with PasswordSignIn');
    }
    final response = await _post('/auth/login', {
      'username': request.username,
      'password': request.password,
    });
    // A form shows this under the password field: nothing to catch in the page.
    if (response.statusCode == 401) {
      throw const FieldErrors({'password': 'Wrong user name or password'});
    }
    return _session(response);
  }

  @override
  Future<AuthSession> refresh(AuthSession session) async {
    final response = await _post('/auth/refresh', {
      'refresh_token': session.tokens.refreshToken,
    });
    // The server refused the refresh token: the session is over. Anything else
    // thrown here (a socket error, a 503) keeps the session and is tried again.
    if (response.statusCode == 400 || response.statusCode == 401) {
      throw const AuthRejected();
    }
    return _session(response, previous: session);
  }

  @override
  Future<void> signOut(AuthSession session) async {
    await _post('/auth/logout', {'refresh_token': session.tokens.refreshToken});
  }

  Future<http.Response> _post(String path, Map<String, Object?> body) async {
    final response = await _client.post(
      base.resolve(path),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode >= 500) {
      throw http.ClientException('HTTP ${response.statusCode}', base.resolve(path));
    }
    return response;
  }

  AuthSession _session(http.Response response, {AuthSession? previous}) {
    final json = jsonDecode(response.body) as Map<String, Object?>;
    final user = json['user'] as Map<String, Object?>?;
    final tokens = AuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      // clock.now(), not DateTime.now(): a test's fake clock ages the token.
      expiresAt: clock.now().add(Duration(seconds: json['expires_in'] as int)),
    );
    return AuthSession(
      backend: name,
      tokens: tokens,
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

AuthConfig authSetup() => AuthConfig(
  backend: ApiBackend(Uri.parse('https://api.example.com')),
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

```dart
// lib/app/sign-in/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

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

Future<List<String>> data(Ref ref) async {
  // Another user loads this again; a token refresh does not.
  ref.watch(authUserId);
  final response = await ref
      .watch(authHttpClient)
      .get(Uri.parse('https://api.example.com/orders'));
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

## Test it

```dart
// test/auth_test.dart
import 'dart:async';

import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
        client: MockClient((request) async {
          sent = request.headers['Authorization'];
          return http.Response('["order 1", "order 2"]', 200);
        }),
      ),
    );
    expect(currentLocation(tester), '/orders');
    expect(find.text('order 2'), findsOneWidget);
    expect(sent, 'Bearer fake-access-0');
  });

  testWidgets('signing in sends the user back, with no navigation code in the page', (tester) async {
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders'),
      overrides: fakeAuth(
        apiOrigins: [api],
        client: MockClient((_) async => http.Response('["order 1"]', 200)),
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

- **No `refreshing` state.** A refresh keeps `SignedIn` and swaps the tokens. Expiry is
  `SignedOut(reason: SignOutReason.expired)`, a server's refusal of the refresh token (`AuthRejected`,
  `invalid_grant`); a network error or a 5xx (`AuthUnavailable`) keeps the session and is tried again by
  the next request.
- **`tokens()` is synchronous while the access token is good** (`expiresAt - leeway` still ahead of
  `clock.now()`), and one shared refresh otherwise: any number of requests that find it expired wait for the
  same `Future`. That is what refresh-token rotation needs (Keycloak's "Revoke Refresh Token" refuses a
  second refresh with the same token). There is **no timer**: nothing refreshes in the background, and a
  test greps `lib/` for `Timer(`, `Future.delayed`, `.listen(` and `DateTime.now()`.
- **`restoreAuth` does no network.** An expired access token is refreshed by the first request that needs
  it, so an offline start works. It drops a stored session of another backend, one whose refresh token has
  expired (`SignedOut(expired)`), and one bound to a DPoP key that is gone (`SignedOut(keyLost)`).
- **Without `restoreAuth`** in `startup()` the session restores itself at the first read: the state is
  `SessionRestoring` while an async store answers, and the guard helpers return a `Future` for that long
  (a blank first frame on a cold deep link). Read the store in `startup()` to avoid it.
- **A sign-out is synchronous**: `signOut()` sets `SignedOut(reason: SignOutReason.user)` before its first
  `await`, so guards move the user in that frame; then the store is cleared, the backend's `signOut` runs
  (its errors are swallowed) and the proof of possession is reset. A button over a page that was
  **pushed** should navigate too (`const HomeRoute().go(context)`): a guard under a pushed page reacts only
  when you pop back (see `auth-patterns.md`).
- **`apiOrigins` is an allow-list** (scheme, host and port). `SessionClient` sends nothing to another host,
  so a token cannot leak to a third party. An empty list is an error the first time `authorizer` is read:
  `fespalier_auth: AuthConfig.apiOrigins is empty, so no request would carry the session; list your API's origins, e.g. apiOrigins: [Uri.parse('https://api.example.com')]`.
- **At most three sends per request**: the first, one after a DPoP nonce challenge, one after a 401 and a
  refresh. A request that cannot be sent again (a `MultipartRequest`, a `StreamedRequest`) is sent once, and
  its caller gets the 401 after the refresh, so the next attempt works.
- **Tokens, ids and e-mails never reach a log, a telemetry attribute or an error text**: `AuthTokens`,
  `AuthUser`, `AuthSession` and `PasswordSignIn` print without them.
- **User data and persistence.** A `data.dart` whose data belongs to the user should
  `ref.watch(authUserId)`; a `dataCache` (since 0.8.1) keeps the previous user's data until it loads again, so
  clear the cache storage on sign-out.
- **One isolate.** The single flight is per `ProviderContainer`. A second isolate or a second web tab that
  refreshes the same rotating token gets `invalid_grant` and signs the user out: refresh in one place, or do
  not turn rotation on.

## Testing

`fakeAuth(signedInAs: ..., backend: ..., store: ..., apiOrigins: ..., client: ..., tokenLifetime: ...)` returns
the overrides for `pumpRouter`; call it **inside the test body**, where the fake clock starts, so
`tester.pump(const Duration(minutes: 6))` ages a session that has a `tokenLifetime`. `FakeAuthBackend` counts
`signIns`, `refreshes` and `signOuts`, fails with `signInError` and `refreshError`, and holds a call open with
`gate` (a `Completer<void>`): the way to see a pending state. In `fsp test`'s `setup.dart`,
`List<Override> overrides(String pattern) => fakeAuth(signedInAs: ...)` makes every guarded route render.
`RecordingTelemetry` sees the `auth` spans (`#2 start auth refresh backend=fake trigger=expired`).
