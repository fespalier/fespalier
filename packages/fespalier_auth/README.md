# fespalier_auth

Signed-in routes for [fespalier](https://github.com/fespalier/fespalier) (since 0.9.0): a session
provider, guards for `guard.dart`, token storage, lazy single-flight refresh and an authenticated
HTTP client, behind one `AuthBackend` interface. fespalier's core has no auth; this package is the
pattern the guards documentation describes, packaged.

The docs cover all of it:
[Authentication](https://github.com/fespalier/fespalier/blob/main/docs/auth.md) (the session, restoring at
start-up, guarding routes, signing in and out, calling your API, testing, telemetry). This page is
the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one
package only if they are the same repository dependency.

<!-- x-release-please-start-version -->
```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.13.1
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: v0.13.1
```
<!-- x-release-please-end -->

Needs Dart 3.8 and Flutter 3.32 or newer. `flutter_secure_storage` (the token store) is the only
plugin it brings; on Android its minSdk is 24. The rest is pure Dart: `http`, `crypto` (PKCE), `clock`
and `dio` (tree-shaken unless you import `package:fespalier_auth/dio.dart`).

## Wire it

Read the stored session before the first frame, from `lib/app/startup.dart` (the generated `main()`
shows `splash.dart` meanwhile):

```dart
// lib/app/startup.dart
import 'dart:async';

import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

FutureOr<List<Override>> startup() => restoreAuth(
  AuthConfig(
    backend: MyBackend(), // an AuthBackend: see below
    apiOrigins: [Uri.parse('https://api.example.com')],
  ),
);
```

Guard the routes that need a session, and let the sign-in page's own guard send the user back:

```dart
// lib/app/(signed-in)/guard.dart: the routes under it need a session
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));

// lib/app/sign-in/guard.dart: signing in on that page sends the user back by itself
GuardResult guard(Ref ref, {String? from}) => redirectIfSignedIn(ref, from: from);
```

Keep `sign-in/` beside `(signed-in)/`, not inside it: a guard on the sign-in page would send the
user to the sign-in page. The page calls
`ref.read(authSession.notifier).signIn(const PasswordSignIn(...))` and has no navigation code.

## Call your API

```dart
// lib/app/(signed-in)/orders/data.dart
Future<List<Order>> data(Ref ref) async {
  ref.watch(authUserId); // another user: load again; a token refresh: nothing
  final response = await ref.watch(authHttpClient).get(Uri.parse('https://api.example.com/orders'));
  return Order.listFromJson(response.body);
}
```

`authHttpClient` attaches the session to requests to `AuthConfig.apiOrigins` only, waits for one
shared refresh when the access token has expired, and sends a request once more after a 401. That one
replay is marked: `isAuthReplay(request)` (`options.extra[authReplayKey]` on dio), so a guard against
re-sent writes can let it through. A request made with `http.AbortableRequest` keeps its abort trigger
on the replay. Do not put `RetryClient` under it (it would re-send the same signature, which a DPoP server
refuses); wrap it: `RetryClient(ref.watch(authHttpClient))`.

With dio: `dio.interceptors.add(SessionInterceptor(ref.watch(authorizer), dio))`, from
`package:fespalier_auth/dio.dart`.

## Backends

An `AuthBackend` says how to sign in, refresh and sign out; the package keeps the session, the
store and the single flight. `FakeAuthBackend` (in `package:fespalier_auth/testing.dart`) is the
smallest example.

- **OpenID Connect and Keycloak**, in the package: `OidcBackend` in `package:fespalier_auth/oidc.dart`,
  the authorization code flow with PKCE for a public client, with Keycloak's endpoints, roles and
  refresh-token rotation. The browser step is a function you give it (`flutter_web_auth_2` is the usual
  one), so the package links no plugin for it. Read against Keycloak 26.8.0; `examples/auth` has the
  realm and a Docker command.
- **Firebase, Supabase and your own API**, as recipes: `skills/fespalier-guards/references/auth-backends.md`
  has code that is compiled by CI. `examples/auth/lib/demo/demo_backend.dart` is a username-and-password
  backend with tests.

## Tests

```dart
import 'package:fespalier_auth/testing.dart';

testWidgets('a member sees the orders', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/orders'),
    overrides: fakeAuth(signedInAs: const AuthUser(id: 'ada', roles: {'admin'})),
  );
  expect(currentLocation(tester), '/orders');
});
```

## What it costs

The package starts no timer, no listener and no `Future.delayed`: a refresh is lazy (the first
request that finds the token expired) and shared, and a test greps the library for those calls. A
synchronous guard stays synchronous, and with `MemoryTokenStore` or a backend that keeps its own
session, so does `restoreAuth`. An app that does not import it is unchanged.
