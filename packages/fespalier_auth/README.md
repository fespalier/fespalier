# fespalier_auth

Signed-in routes for [fespalier](https://github.com/fespalier/fespalier) (since 0.9.0): a session
provider, guards for `guard.dart`, session storage, lazy single-flight renewal and an authenticated
transport, behind one `AuthBackend` interface. fespalier's core has no auth; this package is the
pattern the guards documentation describes, packaged.

Since 0.21.0 it is the **protocol-agnostic core**: it knows a `SessionCredential`, a
`RequestAuthenticator` and an `AuthBackend`, and no token, no OpenID Connect flow and no key.
[`fespalier_oidc`](https://github.com/fespalier/fespalier/blob/main/packages/fespalier_oidc/README.md)
is the token backend (PKCE, Keycloak, bearer and DPoP). It sends only through
`fespalier_transport`'s `HttpTransport`, so it links neither `package:http` nor Dio.

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
      ref: v0.24.0
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: v0.24.0
```
<!-- x-release-please-end -->

Needs Dart 3.9 and Flutter 3.35 or newer. `flutter_secure_storage` (the session store) is the only
plugin it brings; on Android its minSdk is 24. The rest is pure Dart: `clock` and
`fespalier_transport` (at the same tag, which pub resolves for you): the `Authorizer` is an
`HttpCredentials`, and an `AuthAttempt` an `HttpAuthorization`, so a transfer that is not a transport
can take it as it is. There is no `http` and no `dio` in its dependencies (`test/no_http_test.dart`).

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
    transport: HttpClientTransport(http.Client()), // or DioTransport(dio): what requests go through
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
`ref.read(authSession.notifier).signIn(...)` (a `BrowserSignIn` or `PasswordSignIn` from
`fespalier_oidc`, or a request of your backend's own) and has no navigation code.

## Call your API

```dart
// lib/app/(signed-in)/orders/data.dart
Future<List<Order>> data(Ref ref) async {
  ref.watch(authUserId); // another user: load again; a renewal: nothing
  final client = TransportClient(ref.watch(authTransport)); // fespalier_http, for package:http code
  final response = await client.get(Uri.parse('https://api.example.com/orders'));
  return Order.listFromJson(response.body);
}
```

`authTransport` is a `SessionTransport` over `AuthConfig.transport`. It attaches the session to
requests to `AuthConfig.apiOrigins` only, waits for one shared renewal when the credential has
expired, and sends a request once more after a verdict that says so (a 401, a nonce challenge). Every
send is authorized again with the exact bytes of its body, so a signature is fresh each time; the one
replay is marked in `TransportRequest.attributes` (`transportReplayKey`), so a guard against re-sent
writes can let it through. A request with a streamed body is sent once. With Dio, put the session
below `TransportAdapter(authTransport)` (from `fespalier_dio`), so a retrier above it sends through it
again.

## Backends

An `AuthBackend` says how to sign in, renew and sign out, what proves each request (its
`RequestAuthenticator`), and what to forget when the session ends; the package keeps the session, the
store and the single flight. `FakeAuthBackend` (in `package:fespalier_auth/testing.dart`) is the
smallest example.

- **OpenID Connect and Keycloak**, in `fespalier_oidc`: `OidcBackend`, the authorization code flow
  with PKCE for a public client, with Keycloak's endpoints, roles and refresh-token rotation. The
  browser step is a function you give it (`flutter_web_auth_2` is the usual one), so the package
  links no plugin for it. Read against Keycloak 26.8.0; `examples/auth` has the realm and a Docker
  command.
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

The package starts no timer, no listener and no `Future.delayed`: a renewal is lazy (the first
request that finds the credential expired) and shared, and a test greps the library for those calls. A
synchronous guard stays synchronous, and with `MemoryTokenStore` or a backend that keeps its own
session, so does `restoreAuth`. An app that does not import it is unchanged.
