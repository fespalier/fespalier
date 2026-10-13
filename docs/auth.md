# Authentication

Since 0.9.0. `package:fespalier_auth` is the pattern of [Guards](guards.md) packaged: a session provider, guards for `guard.dart`, token storage, lazy refresh with a single flight and an authenticated HTTP client, behind one `AuthBackend` interface. It adds no timer and no listener.

- **The session** is a provider, `authSession`, whose state is sealed: `SessionRestoring`, `SignedOut(reason)` and `SignedIn(session)`.
- **`restoreAuth(config)`** in `startup()` reads the stored session before the first frame, and never touches the network.
- **The guard helpers** (`requireSignedIn`, `requireRole`, `requireUser`, `redirectIfSignedIn`) are plain Dart over a `Ref`, so a guard stays synchronous, and signing in navigates back by itself.
- **`authHttpClient`** is a `package:http` client that attaches the session to your API's requests, refreshes once when the token has expired and sends a request again after a 401.
- **`package:fespalier_auth/testing.dart`** has `fakeAuth(...)`: a signed-in or signed-out test in one line.

## Installing fespalier_auth

Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: v0.15.0
```

<!-- x-release-please-end -->

Its one plugin is `flutter_secure_storage` (the token store; Android minSdk 24, `>=10.0.0 <12.0.0` accepted), which is in every app that imports the package, whichever backend it uses. A backend that is an SDK of its own (Firebase, Supabase) keeps its own session and does not use the store.

## The session

```dart
final state = ref.watch(authSession); // SessionRestoring | SignedOut | SignedIn
```

| Provider                         | What it is                                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `authSession`                    | The `SessionState`, and `ref.read(authSession.notifier)` for `signIn`, `adopt`, `signOut` and `tokens()`. Not auto-disposed           |
| `isSignedIn` (a `bool`)          | What a guard watches: a token refresh does not change it                                                                              |
| `authUser` (`AuthUser?`)         | The user: `id`, `roles`, `claims`, `email`, `name`. Changes when the user or their roles do, never on a refresh that changes nothing  |
| `authUserId` (`String?`)         | Watch it in a `data.dart` whose data belongs to the user: another user loads it again, a token refresh does not                       |
| `authConfig`, `authInitialState` | The app's `AuthConfig`, and what `restoreAuth` read. Reading `authConfig` with no override throws a `StateError` that says what to do |

There is **no `refreshing` state**: a refresh keeps `SignedIn` and swaps the tokens, so a guard that watches the session never runs again, and a request is never bounced to the sign-in page in the middle of one.

`SignedOut` carries a `SignOutReason`: `expired` (the server refused the refresh token: the sign-in page can say "your session expired"), `user` (a sign-out) or `keyLost` (a session bound to a device key that is gone, see below).

`AuthTokens`, `AuthUser`, `AuthSession` and `PasswordSignIn` print without a token, an id, an e-mail or a password (`AuthUser(roles: {admin})`), so a log line is safe. `unverifiedJwtClaims(token)` reads a JWT's payload for display and routing; it does not verify it, and the server still decides.

## Restoring at startup

```dart
// lib/app/startup.dart
FutureOr<List<Override>> startup() => restoreAuth(authSetup());

// lib/auth_setup.dart
AuthConfig authSetup() => AuthConfig(
  backend: ApiBackend(Uri.parse('https://api.example.com')), // an AuthBackend
  apiOrigins: [Uri.parse('https://api.example.com')],        // where the session is sent: nothing else
);
```

`restoreAuth` returns the overrides for the app's `ProviderScope` (the generated `main()` calls [`startup()`](app-startup.md) and passes them), so every guard is synchronous from the first navigation: a cold deep link to a signed-in page has no blank frame and no redirect.

- It is **synchronous** when the store answers synchronously (`MemoryTokenStore`, a backend that keeps its own session), and one keychain read otherwise (`SecureTokenStore`, the default), shown behind `splash.dart`, or the native splash when there is none.
- It does **no network**: an expired access token is refreshed by the first request that needs it, so an offline start works.

It drops what it cannot trust, without a request:

| Stored session                                                                                  | Result                                                                                                      |
| ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| none                                                                                            | `SignedOut()`                                                                                               |
| another backend's (`AuthBackend.name` differs)                                                  | deleted, `SignedOut()`                                                                                      |
| refresh token expired (`refresh_expires_in`), or the access token expired with no refresh token | deleted, `SignedOut(reason: SignOutReason.expired)`                                                         |
| bound to a DPoP key that is gone, or another                                                    | deleted, `SignedOut(reason: SignOutReason.keyLost)`                                                         |
| corrupt                                                                                         | reported (`FlutterError.reportError`, context `while restoring the stored session`), deleted, `SignedOut()` |

A store that cannot be read at all (a locked keychain) makes `startup()` fail, which the generated `main()` shows with a retry. `AuthConfig` has `backend`, `store`, `apiOrigins` and `leeway` (30 seconds before expiry an access token counts as expired). Install the telemetry sink first in `startup()` to see the restore as a span.

**Where the session is stored.** A stored session is `AuthSession.toJson` under one key (`fespalier_auth.session`): on Apple in the Keychain with `first_unlock_this_device` (not in backups, not on another device); on Android in encrypted storage; on the web in encrypted `localStorage`, which a script on the page can read, so use `MemoryTokenStore` there (a reload signs out) for anything that matters.

An app with no `startup.dart` still works: add `authConfig.overrideWithValue(config)` to the `ProviderScope`, and the session restores itself at the first read. The state is `SessionRestoring` meanwhile, and the guard helpers return a `Future` for that long, which costs a frame.

## Guarding signed-in routes

```dart
// lib/app/(signed-in)/guard.dart: every route under the group needs a session
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));

// lib/app/(signed-in)/admin/guard.dart: and this one an admin
GuardResult guard(Ref ref, {required Uri uri}) => requireRole(
  ref, uri, 'admin',
  signIn: (from) => SignInRoute(from: from),
  forbidden: const ForbiddenRoute(),
);

// lib/app/sign-in/guard.dart: the sign-in page's own guard, beside the group
GuardResult guard(Ref ref, {String? from}) => redirectIfSignedIn(ref, from: from);
```

- **`requireSignedIn(ref, uri, signIn:)`** returns `null` when signed in, else `signIn(uri.toString()).location`: a typed call the compiler checks, with the requested location (query included) as `from`. It watches only the session's phase, so it runs again on sign-out (the user is moved in that frame) and never on a refresh. It answers **synchronously**, unless the session is still being restored.
- **`requireRole(ref, uri, role, signIn:, forbidden:)`** is `requireSignedIn`, then `forbidden` when the user lacks the role. **`requireUser(ref, uri, test, ...)`** takes a function of the `AuthUser` instead. They watch only their own answer, so a role gained or lost runs the guard again, and a refresh does not.
- **`redirectIfSignedIn(ref, from:)`** is for the **sign-in route's own** `guard.dart`: when there is a session it returns `returnTo(from)`. It watches the session, so **signing in on that page sends the user back to `from` by itself**, and the page has no navigation code. `returnTo` refuses `//host`, `https://…` and `/\`, so a crafted `?from=` cannot send the user elsewhere.
- **The sign-in page sits beside the guarded group**, never inside it: a guard on the sign-in page would send the user to the sign-in page.
- A guard under a **pushed** page reacts only when you pop back to it (see [Guards](guards.md)), so a sign-out button over a pushed page should navigate too: `const HomeRoute().go(context)`.
- A guard is not access control: the server decides what a token may do.

## Signing in and out

The sign-in page is a [form on an action](forms.md) (`fespalier_forms`, which the app's `pubspec.yaml` needs for it), and the backend throws `FieldErrors` for wrong credentials, which the form shows under its field:

```dart
// lib/app/sign-in/action.dart
typedef SignInFields = ({String username, String password});

SignInFields form() => (username: '', password: '');

FieldErrors? validate(SignInFields input) => FieldErrors({
  if (input.username.trim().isEmpty) 'username': 'Enter your user name',
  if (input.password.isEmpty) 'password': 'Enter your password',
});

Future<void> action(Ref ref, {required SignInFields input}) async {
  await ref
      .read(authSession.notifier)
      .signIn(PasswordSignIn(username: input.username.trim(), password: input.password));
}
```

`signIn(request)` asks the backend, **stores the session, then** sets `SignedIn`, and rethrows what the backend threw with the state unchanged: `AuthCancelled` (the user closed a browser sign-in), `FieldErrors` (wrong credentials), `AuthRejected` (the server refused), or any other error (it could not ask). A sign-in overtaken by another one, or by a sign-out, throws `NotSignedIn` and changes nothing. The request is typed: `PasswordSignIn`, `BrowserSignIn`, or a subclass of `SignInRequest` of your own, so a page is the same whichever backend is configured, and a test swaps in `FakeAuthBackend`. `adopt(session)` signs in with a session the app obtained itself (a deep-link callback, a multi-step SDK flow), and throws an `ArgumentError` when it comes from another backend than the configured one.

`signOut()` sets `SignedOut(reason: SignOutReason.user)` **synchronously**, so the guards move the user in that frame, then clears the store, runs the backend's `signOut` (best effort: its errors are swallowed) and resets the proof of possession. It does nothing when nobody is signed in.

**A backend** is `AuthBackend`: `name` (a short constant, `oidc`, `firebase`, `api`: what a stored session is tied to, and telemetry's `fespalier.auth.backend`), `signIn`, `refresh` and `signOut`. `refresh` throws `AuthRejected` when the server refused (the session is over) and anything else when it could not ask (the session stays). The starter in `skills/fespalier-guards/references/auth-package.md` is a complete one over a JSON API: a `POST /auth/login` and `/auth/refresh`.

## Calling your API

```dart
// lib/app/(signed-in)/orders/data.dart
Future<List<Order>> data(Ref ref) async {
  ref.watch(authUserId); // another user: load again; a token refresh: nothing
  final response = await ref.watch(authHttpClient).get(Uri.parse('https://api.example.com/orders'));
  if (response.statusCode != 200) throw ApiError(response.statusCode);
  return Order.listFromJson(response.body);
}
```

`authHttpClient` is a `SessionClient` on `authBaseClient` (override it with a `MockClient` in a test). A request to an origin in `AuthConfig.apiOrigins` carries `Authorization: Bearer <token>`; any other origin gets nothing, so a token cannot leak to a third party, and `apiOrigins` empty is an error the first time `authorizer` is read.

- **Refresh is lazy and single-flight, with no timer.** `ref.read(authSession.notifier).tokens()` returns the tokens **synchronously** while the access token is good, and starts one shared refresh when it has expired (`expiresAt` less `leeway`, against `clock.now()`), after a 401 to the token in use, or when forced. Any number of requests that find it expired wait for the same `Future`: with refresh-token rotation (Keycloak's "Revoke Refresh Token"), a second refresh with the same token would sign the user out. The new tokens are stored before the state publishes them, so a kill between the two leaves the store on the token the server accepts.
- **A refresh the server refuses** (`AuthRejected`, an OAuth `invalid_grant`) signs the user out with `expired` and clears the store. **One that could not run** (offline, a 5xx: `AuthUnavailable`, a `ClientException`) keeps the session, and the next request asks again.
- **At most three sends per request**: the first, one after a DPoP nonce challenge, and one after a 401 and a refresh. Only a request that can be sent again (what `get`, `post`, `put`, `patch` and `delete` make) is: a multipart or streamed body is sent once, and its caller gets the 401, after the refresh, so its next attempt works. A second 401 is returned as it is.
- **For a client of your own**, `ref.watch(authorizer)` has `authorize(method, uri)` (the headers) and `retry(attempt, statusCode:, headers:)` (send again?).
- **One container.** The single flight is per `ProviderContainer`: a second isolate or a second web tab that refreshes the same rotating token gets `invalid_grant`. Refresh in one place, or do not turn rotation on.
- **A replay is marked, and keeps its abort trigger.** A request sent again (after a 401 and a refresh, or after a DPoP nonce challenge) is `isAuthReplay(request)` for `SessionClient` and `options.extra[authReplayKey]` (`'fespalier.auth.replay'`) for `SessionInterceptor`, so a guard that refuses re-sends of writes can let that one through; the first send is not a replay. A request made with `http.AbortableRequest(..., abortTrigger: future)` is copied with the same trigger (`package:http` 1.5.0 and later), so aborting still cancels the replay when the page that wanted it goes away.
- **Do not put `RetryClient` under the session.** `package:http`'s `RetryClient` sends the same headers again, so under a client that signs requests it re-sends the same signature. With DPoP that is the same proof, and the server refuses a reused `jti` (Keycloak answers `invalid_request` with `DPoP proof has already been used`). Wrap the session client instead, `RetryClient(ref.watch(authHttpClient))`, so each attempt asks the authorizer for a proof of its own, and do not override `authBaseClient` with a `RetryClient` when the backend uses DPoP.
- **User data across users.** A `dataCache` keeps the previous user's data until it loads again: watch `authUserId` in user-owned data and clear the cache storage on sign-out.

## OpenID Connect and Keycloak

`package:fespalier_auth/oidc.dart` (a separate library: an app that signs in some other way links none of it) has `OidcBackend`: the authorization code flow with PKCE (S256) for a **public** client, in pure Dart over `package:http`, with Keycloak's defaults. It owns the token exchange and the refresh, which is what makes the single flight, refresh-token rotation and [DPoP](#device-bound-tokens-dpop-with-fespalier_sign_keypair) on the token endpoint possible. The browser step is a function you give it, so the package links no plugin: `flutter_web_auth_2` (MIT; Android, iOS, macOS, web, Windows and Linux) is the usual one.

```dart
// lib/auth_setup.dart
final issuer = Uri.parse('https://sso.example.com/realms/shop');

AuthConfig authSetup() => AuthConfig(
  backend: OidcBackend(
    issuer: issuer,
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    endpoints: OidcEndpoints.keycloak(issuer), // no discovery request
    openBrowser: openBrowser,
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);

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
```

The sign-in button calls `ref.read(authSession.notifier).signIn(const BrowserSignIn())` straight from its `onPressed` (a web popup is blocked when `signIn` runs later), and catches `AuthCancelled`. The sign-in guard moves the user. `BrowserSignIn` has `loginHint`, `prompt` (`login` shows the form over a single-sign-on cookie, `none` fails with `login_required`) and `parameters` (`{'kc_idp_hint': 'google'}`).

- **What it checks.** The redirect: its `state`, its `error` (`access_denied` is `AuthCancelled`, anything else an `OidcException`), its `iss` when present (RFC 9207, which Keycloak sends) and its `code`. Then the ID token's `iss`, `aud` and `nonce`. The ID token's signature is **not** verified (OpenID Connect Core 3.1.3.7: it came straight from the token endpoint over TLS). Every message is in the troubleshooting skill.
- **Roles** come from the access token: `realm_access.roles` and `resource_access.<clientId>.roles` (`keycloakRoles(clientId)`, the default; pass `roles:` to read another claim). Keycloak does not put them in the ID token unless a mapper does.
- **Discovery.** `OidcEndpoints.keycloak(issuer)` spells Keycloak's four endpoints, and `OidcEndpoints.discover(issuer)` reads `<issuer>/.well-known/openid-configuration` and refuses a document whose `issuer` is another one. Leave `endpoints:` out and discovery runs at the first sign-in or refresh, once.
- **Sign-out** revokes the refresh token (RFC 7009), which makes Keycloak end the whole session, best effort. `endBrowserSession(session)` also ends the browser's single-sign-on session through the end-session endpoint; with `preferEphemeral: true` there is none to end.
- **No timeout of its own** (that would be a timer): pass `client:` an `http.Client` that times out if you want one. A confidential client (a `client_secret`) is out of scope: a mobile or web app is a public client.

**Keycloak settings and traps**, read from a live Keycloak 26.8.0 (`examples/auth/keycloak/realm-fespalier.json` is a realm exported from it):

- A **public client** with Standard flow on, Direct access grants off, and the client attribute `pkce.code.challenge.method` set to `S256` (without a challenge the authorization endpoint answers `error=invalid_request&error_description=Missing+parameter%3A+code_challenge_method`). Its **valid redirect URIs** must list `redirectUri` exactly.
- **"Revoke Refresh Token"** makes a refresh token good once: a second refresh with the same one answers `invalid_grant` with `Maximum allowed refresh token reuse exceeded`, **and the whole session is then gone**. That is why the refresh is a single flight, and why two isolates or two web tabs that share a session sign each other out.
- **The refresh token lives as long as the SSO session's idle timeout** (30 minutes by default; the token response's `refresh_expires_in` says): a user who is away longer gets `invalid_grant` with `Token is not active`. For longer sessions ask for the `offline_access` scope (`OidcBackend(scopes: ['openid', 'profile', 'email', 'offline_access'])`).
- **The issuer is Keycloak's configured hostname.** With `--hostname=http://10.0.2.2:8080` every token says `http://10.0.2.2:8080/realms/...`, so an app that reaches the same Keycloak as `localhost` gets `the ID token was
issued by ..., not ...`. On an Android emulator, use `adb reverse tcp:8080 tcp:8080` and `localhost`, or give Keycloak the `10.0.2.2` hostname.
- **A single-sign-on cookie signs the user in again silently** after a sign-out, unless the browser session is ephemeral (`preferEphemeral: true`) or the sign-in asks `BrowserSignIn(prompt: 'login')`.

## Firebase, Supabase and your own API

Firebase's and Supabase's SDKs keep the session and refresh it themselves, so their backends say `keepsOwnSession`: the token store is not used, `currentSession()` is read once at start-up (a one-shot read of the SDK, so the framework holds no listener), and `refresh` asks the SDK for new tokens. They are **recipes, not packages**: a first-party package for each would add a heavy SDK to every app and a release surface. The code is in `skills/fespalier-guards/references/auth-backends.md`:

- **Firebase** (`firebase_auth`, no Linux): `signIn(PasswordSignIn)` is `signInWithEmailAndPassword`, whose `wrong-password`, `invalid-credential` and `user-not-found` become `FieldErrors`; `refresh` is `getIdTokenResult(true)`, and `user-disabled` or `user-token-expired` become `AuthRejected`. Initialise Firebase in `startup()` before `restoreAuth`.
- **Supabase** (`supabase_flutter`): its client **auto-refreshes with a timer by default**, so initialise it with `authOptions: FlutterAuthClientOptions(autoRefreshToken: false)` and refresh lazily with `refreshSession()`. Import it with a prefix: `gotrue` exports `AuthState`, `Session` and `User`.
- **Your own API** (a username and a password): `examples/auth/lib/demo/demo_backend.dart`. A wrong password is a `FieldErrors`, a refused refresh token is `AuthRejected`, and a socket error or a 5xx keeps the session.

`package:fespalier_auth/dio.dart` has `SessionInterceptor(authorizer, dio)`, the policy of `authHttpClient` on dio's types: `dio.interceptors.add(SessionInterceptor(ref.watch(authorizer), dio))`. `FormData` bodies are not sent again, and a refresh that could not run is a `DioException` whose `error` is the `AuthUnavailable`. dio is a dependency of `fespalier_auth`, and is tree-shaken when that library is not imported.

## Device-bound tokens: DPoP with fespalier_sign_keypair

`package:fespalier_sign_keypair` (a separate package, since 0.9.0) is **DPoP** ([RFC 9449](https://www.rfc-editor.org/rfc/rfc9449)) for `OidcBackend`: every token request, refresh and API call carries a proof, a JWT signed by a key that lives in the Secure Enclave (iOS, macOS) or the AndroidKeyStore (StrongBox or the TEE), through [flutter-sign-keypair](https://github.com/vaam-apps/flutter-sign-keypair). The server binds the access and refresh tokens to that key (`cnf.jkt`), so a token copied off the device is useless without the device. It implements `fespalier_auth`'s `ProofOfPossession`, so nothing else in the app changes:

```dart
// lib/auth_setup.dart
AuthConfig authSetup() => AuthConfig(
  backend: OidcBackend(
    issuer: issuer,
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    endpoints: OidcEndpoints.keycloak(issuer),
    openBrowser: openBrowser,
    proof: DpopProof.device(), // throws DpopUnavailable on the web unless a fallback is given
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

Install it next to `fespalier` and `fespalier_auth`, with the same `url` and `ref` for the three (its README has the block). It needs Dart 3.12 and Flutter 3.44, Android minSdk 24, iOS 15 and macOS 10.15, and it depends on flutter-sign-keypair **by git, pinned to a commit** (the repository is not on pub.dev), so `flutter pub get` clones `github.com/vaam-apps/flutter-sign-keypair`.

- **What is sent.** A proof is `{typ: dpop+jwt, alg: ES256, jwk}` and `{jti, htm, htu, iat, ath?, nonce?}`, ES256 signed: `jti` is new for every send (retries included), `htu` has no query or fragment, `ath` is only on requests that carry an access token, and the authorization request carries `dpop_jkt`, so the code is bound to the key too. One signature per request, made by the secure element; nothing is cached (a proof is single-use), and no timer or listener is started.
- **Nonces and the clock.** A `DPoP-Nonce` from any response is kept per origin, and a `use_dpop_nonce` challenge (an authorization server's `400`, a resource server's `401`) is answered once. When a server refuses a proof as not active and its `Date` header says the device clock is more than 5 seconds off, the difference is applied to every later `iat` and the request is sent once more. **Keycloak sends neither a nonce nor a `Date`**, so a wrong clock there is `invalid_request` / `DPoP proof is not active`: set the clock.
- **The key.** An _ambient_ key (it never prompts), made on first use under the key id `fespalier_dpop`. Sign-out deletes it (`rotateKeyOnSignOut`), so the next sign-in makes a new one and an old refresh token, even a stolen one, is useless. `restoreAuth` signs the user out (`SignedOut(reason: SignOutReason.keyLost)`) when the key a stored session is bound to is gone: a restored backup, a wiped keychain.
- **Where there is no secure element** (the web, Windows, Linux, Fuchsia) `DpopFallback.refuse`, the default, throws `DpopUnavailable`: a library that promises tokens bound to a device must not quietly give you tokens bound to nothing. `DpopFallback.software` is a key in memory (its scalar is in the process; on the web it does not survive a reload, so the session is signed out, unless you pass a `softwareStore`), and `DpopFallback.bearer` is no DPoP (`device()` returns null; the client must not require DPoP-bound tokens). `requireHardware: true` makes a device without a secure element fail instead (the iOS simulator has only the keychain).
- **Keycloak** supports DPoP since 26.4. Switch on **Require DPoP bound tokens** on the client (the attribute `dpop.bound.access.tokens`; `examples/auth/keycloak/` has a realm with such a client, `fespalier-auth-example-dpop`). Read from Keycloak 26.8.0: errors are `invalid_request` with descriptions (`DPoP proof is missing`, `DPoP proof is not active`, `DPoP proof has already been used`), a refresh token bound to another key is `invalid_grant` / `DPoP confirmation doesn't match DPoP proof`, and a resource server's 401 is `WWW-Authenticate: DPoP ... error="invalid_token"` for every problem with the proof.
- **`RetryClient` goes over the session client**, never under it (see Calling your API).
- **Tests.** `package:fespalier_sign_keypair/testing.dart` has `FakeDpopSigner` (a software key from a fixed scalar: the same key and signature on every run) and `verifyDpopProof`, which a fake server checks every proof with and which names the first check that failed. `examples/auth` runs a DPoP-checking demo server.

## Testing signed-in routes

`package:fespalier_auth/testing.dart` has `fakeAuth(...)`, the overrides for `pumpRouter`: signed in as the `AuthUser` you give, or signed out, on a `FakeAuthBackend` and a `MemoryTokenStore`, with no `startup()` and no network:

```dart
testWidgets('a member sees the orders', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/orders'),
    overrides: fakeAuth(signedInAs: const AuthUser(id: 'ada', roles: {'admin'})),
  );
  expect(currentLocation(tester), '/orders');
});
```

Call it inside the test body, where the fake clock starts. Pass `backend:` to read its counters (`signIns`, `refreshes`, `signOuts`), to make it fail (`signInError`, `refreshError`) or to hold a call open (`gate`, a `Completer<void>`: a pending state to look at), `tokenLifetime:` to age the session with `tester.pump(const Duration(minutes: 6))`, `apiOrigins:` and `client:` (a `MockClient`) to test an API call. Signed out, a guarded route lands on `/sign-in?from=%2Forders`. In [`fsp test`](route-tests.md#route-smoke-tests-fsp-test), the setup file returns `fakeAuth(signedInAs: …)` from `overrides`, so guarded routes render:

```dart
// test/routes/setup.dart
List<Override> overrides(String pattern) => fakeAuth(signedInAs: const AuthUser(id: 'ada'));
```

`FakeProof` stands in for a proof of possession, and `RecordingTelemetry` sees the `auth` spans (`#2 start auth
refresh backend=fake trigger=expired`); [Telemetry conventions](telemetry-conventions.md#telemetry-conventions) lists their attributes.
