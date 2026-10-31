---
name: fespalier-guards
description: "Guarding and redirecting routes in fespalier — guard.dart (a function over a Riverpod Ref that returns a location or null, for a folder and everything below it, in page-less groups too, and that runs again when what it watches changes), redirect.dart routes, the order guards run in, the uri parameter and returnTo for sending people back after sign-in, async guards, and auth patterns such as a session provider, a login page outside the guarded folder, and sign-out moving you to login. Since 0.9.0 also the fespalier_auth package (protocol-agnostic since 0.21.0): a session provider, restoreAuth in startup.dart, requireSignedIn, requireRole and redirectIfSignedIn guards, session storage, lazy single-flight renewal, a session transport (authTransport, over an HttpTransport you give AuthConfig), the AuthBackend you plug in (fespalier_oidc for OpenID Connect with PKCE and Keycloak, recipes for Firebase, Supabase and your own API), device-bound tokens (DPoP, fespalier_keypair_dpop), since 0.21.0 token-free device-signed sessions (fespalier_sign_keypair: enrolment, a signature per request, renewal by re-attestation, user-present keys), since 0.25.0 step-up authentication (RFC 9470 insufficient_user_authentication: one re-proof, one retry, the StepUp verdict, AuthBackend.stepUp, OidcBackend with acr_values and max_age) and routes that need a recent sign-in (requireFreshAuth, redirectIfFreshAuth, AuthSession.authenticatedAt), and a fake backend for tests, and the fespalier_flags package for feature flags (flagGuard in a guard.dart, menus that follow a flag, a synchronous flag provider, vendor sources, FakeFlags). Since 0.13.0 also the fespalier_biometrics package: a biometric unlock guard that never prompts (requireUnlocked redirects to the app's unlock page), a single-flight unlock(), withBiometrics for actions, relock on resume, since 0.19.0 an idle lock (idleTimeout, a ticker the app fires, BiometricActivity) and BiometricLockScreen (an unlock page body that prompts only when tapped; the auto-prompt is the unlock folder's observe.dart onEnter), secrets behind the biometric (BiometricSecrets, readSecret, writeSecret, deleteSecret; the keystore's gate; a read does not unlock the app; a flutter_secure_storage recipe), local_auth as a recipe (2.x and 3.x) and FakeBiometricPrompt and FakeBiometricSecrets. Load before adding a guard or redirect, wiring sign-in and sign-out, or when a guard loops, never runs, or shows not_found.dart at the login page."
---

# fespalier-guards

> **Verified against fespalier `589cf391` (2026-10-08), release v0.13.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

## A guard

```dart
// (members)/guard.dart: guards /inbox, /admin and everything in the group
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/auth.dart';

GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

`GuardResult` is `FutureOr<String?>`: **a location to redirect to, or `null` to
let the navigation through**; it may be async, but return synchronously when you
can (any `Future`, even `Future.value(...)`, costs a frame and a blank first frame on a
cold deep link). A guard covers **every route at and
below its folder**, and the folder needs no `page.dart`: put the guard in a
`(group)` (or at the root) to cover a whole section.

- **Parameters.** First the `Ref ref` (positional; the older `ProviderContainer c` is
  still accepted), then **named**:
  `uri` (the requested location, query included), `extra`, the segments of its own
  folder and above (`{required String shop}`), and optional nullable query
  parameters. A guard **above** `$id` cannot ask for `id`.
- **Order.** Outermost first; **the first guard to return a location wins**; a
  folder's own guard runs after the ones above it, so an inner guard may assume what
  an outer one checked. The location a guard returns is navigated to and **its** guards
  run in turn.
- **No double runs.** Each page's `GoRoute` gets the `redirect`; nested pages go
  through their parent's, and shells get none (go_router runs a matched route's
  redirect for deep links and for navigation inside shells, tabs included).
- **It takes a `Ref`, not a `WidgetRef`** (a guard has no widget:
  ``a guard runs outside the widget tree: take `Ref` ``). **`ref.watch` a provider
  and the guard runs again when it changes** (since 0.5.0): if the new answer differs
  from the one the navigation used, the router runs the redirects again. Signing out
  on `/inbox` moves you to login by itself, a pushed page too (since 0.21.0, see "Signing out
  moves you" below).
- **Stay sync when you can.** A guard that answers synchronously adds no frame and
  boots with no blank first frame; **any** `Future`, even a completed one, costs a
  frame. Return a `Future` only when you await something.
- A `guard.dart` with no route at or below its folder is a **warning**.
- **To redirect, use a guard, not an `onEnter`** (since 0.8.1): an `observe.dart` hook runs after the
  navigation committed and cannot veto it. See [`fespalier-observability`](../fespalier-observability/SKILL.md).
- **A guard is not access control**: the server must still authorise the data.

## Keep the login page outside the guard

A guard covers everything below it, so a `login/` folder inside the guarded group is
redirected to itself (`/login?from=/login?from=...`); go_router gives up at its
redirect limit and the router's error builder shows your `not_found.dart`:
**"Nothing at /login"**, location stuck where it was. Put `login/` **beside** the
guarded group, never inside it.

## Sending people back

```dart
LoginRoute(from: uri.toString()).location   // /login?from=%2Finbox%3Ffolder%3Dsent

// login/page.dart, when sign-in succeeds:
context.go(returnTo(from));                  // from if it is an absolute in-app path, else '/'
context.go(returnTo(from, fallback: '/home'));
```

`returnTo` lets only an **absolute in-app path** through; `https://...`, `//host`,
`/\host` and `javascript:` all fall back, so a crafted `?from=` cannot send people
off your app.

## `redirect.dart`

```dart
// old-inbox/redirect.dart: /old-inbox?folder=sent -> /inbox?folder=sent
import 'package:my_app/app.g.dart';

String redirect({String? folder}) => InboxRoute(folder: folder).location;
```

A folder has a `redirect.dart` **instead of** a `page.dart`. It takes a guard's
parameters (the first one, `Ref ref`, is optional since 0.5.0, as is the older
`ProviderContainer c`), inherits the guards above it, gets a typed route named after its
path (`OldInboxRoute`), and its target's guards run in turn. A tab layout's own folder
cannot hold one. It runs once per navigation and does not watch: a redirect route
never stays on screen.

## Two behaviours that surprise

- **An unparsable segment skips only the guards that read segments or query
  parameters.** `/vault/abc` (an `int id`) skips a `guard(..., {required int id})`
  and shows not-found, but a guard that asks for neither (for instance the
  `(members)` one above, which takes only `uri`) **still runs**, so `/items/abc`
  under it redirects to login first. (The 0.3.0 README said all guards are skipped.)
- **Signing out moves you, if the guard watches (since 0.5.0).** A guard that
  `ref.watch`es the session runs again when it changes, with `AppRoutes.router()` and
  with a router of your own built from `AppRoutes.mount()`, with no
  `refreshListenable`. Three limits: a guard of a **base page under a pushed page** (guarded or not) is not watched while it is covered, and is
  not run again by the app bar's back button, `Navigator.pop` or the system back, only by `GoRouter.pop` and `context.pop` of a page with no `leave.dart` (a guarded pushed page runs its guard again however it is uncovered; a guard on the page on top reacts itself while it is on top: with a base page under a redirect the router is refreshed first, so a sign-out that a guard notices replaces the whole stack and a change only the top page's guard notices can ask a dirty page's `leave()` twice, once for the refresh and once for the re-run; with none under it, the page moves alone and asks once); a guard that takes `ProviderContainer c` (or only `ref.read`s) never runs
  again by itself, as on 0.4.1 and earlier, where **no** guard did; and a sign-out runs
  the guard **twice** (Riverpod recomputes it, then the router asks), without
  fetching the providers it watches twice. **Don't `ref.keepAlive()` in a guard**: it
  leaks a provider per navigation. A guard that throws never moves the router: on a
  navigation its failure shows the route's error.dart (or the not-found view), reported once in
  every build mode through `FlutterError.onError`, on every go_router (since 0.21.0).
  Details and a compiled sample: [`references/auth-patterns.md`](references/auth-patterns.md).
- **DevTools shows each decision (since 0.7.0).** Its **Guards** tab lists every guard and
  `redirect.dart` that answered, with `pass`, `redirect` (and where to), `pending` or `error` for an
  async guard, or `skipped` when a segment did not parse; a redirect chain is one history entry.
  The generated `redirect:` wraps each call in `traceGuard`, which returns the guard's own result, so
  a sync guard stays sync (`fespalier-troubleshooting`, its DevTools page); since 0.21.0 that sits inside
  `runRedirect`, which returns a sync answer as it is (the very object, still sync) and, for an async guard,
  a new `Future` with the same value, or with the failure as a `GuardFailure`.

- **A menu runs your guards too (since 0.8.1).** `AppMenu.watch(ref)` (generated from `nav.dart`
  files) asks the guards that run for each guarded entry, with the entry's own location, to list,
  switch off or hide it. It follows a `Ref` guard's `ref.watch`es, shows an entry pending while an
  async guard is out, and reads a `ProviderContainer c` guard once. Keep guards cheap and free of
  side effects (`fespalier-layouts`, its page on menus and breadcrumbs).

## `fespalier_auth` (since 0.9.0)

fespalier's core has **no auth feature**; the `fespalier_auth` package (a git dependency next to fespalier, **same
`url`, same `ref`**) packages the pattern below: a session provider (`authSession`), `restoreAuth` for `startup()`,
session storage, **lazy single-flight renewal with no timer**, guard helpers and a transport that attaches the
session to your API. It changes no generated code, adds no file kind, key or command.

**Since 0.21.0 it is the protocol-agnostic core.** It knows a `SessionCredential`, a `RequestAuthenticator` and an
`AuthBackend`, never a token or a key; what proves a session is a **backend** you add (`fespalier_oidc` for OpenID
Connect and Keycloak, `fespalier_keypair_dpop` on top for DPoP, `fespalier_sign_keypair` for device-signed sessions, or
your own), and what sends is an `HttpTransport` (`fespalier_transport`; `HttpClientTransport` from `fespalier_http`,
`DioTransport` from `fespalier_dio`) that `AuthConfig(transport:)` requires. What 0.20.0 called these things is in `fespalier-migration`.

```dart
// app/(signed-in)/guard.dart: the group needs a session; sign-in/ sits BESIDE it
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));

// app/sign-in/guard.dart: the trap. Without it, signing in changes the session and nothing moves
GuardResult guard(Ref ref, {String? from}) => redirectIfSignedIn(ref, from: from);

// app/startup.dart
FutureOr<List<Override>> startup() => restoreAuth(authSetup());

// auth_setup.dart: one transport, no session on it; apiOrigins is where the session is sent
AuthConfig authSetup() => AuthConfig(
  backend: ApiBackend(Uri.parse('https://api.example.com'), transport),
  transport: transport,
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

- **`redirectIfSignedIn` is what sends the user back.** It watches the session, so signing in on the sign-in page
  navigates to `from` by itself; the page has no `context.go`. `returnTo` refuses `//host` and `https://…`.
- **No `renewing` state.** A renewal keeps `SignedIn`; `isSignedIn` and `authUser` do not notify on a credential swap,
  so no guard runs again. A refused renewal is `SignedOut(reason: SignOutReason.expired)`; a network error keeps the
  session (`AuthUnavailable`). `SignOutReason` is `expired`, `user`, `keyLost` and, since 0.21.0, `revoked`.
- **Guards stay synchronous** once `startup()` returns `restoreAuth(...)` (no network, ever: an expired credential is
  renewed by the first request). Without it the guards answer a `Future` while the session restores. **A session stored
  by 0.20.0 or earlier is dropped at restore** (`fespalier_auth: unknown stored session version 1`, reported once): the
  user signs in once more.
- **`authTransport` sends the session only to `AuthConfig.apiOrigins`**, renews once when the credential has expired
  (shared by every request that finds it so: refresh-token rotation needs one renewal), and sends a request again after
  a verdict that says so, at most four sends (three before 0.25.0). When a credential counts as expired is the backend's
  (`AuthBackend.renewAhead`; was `AuthConfig.leeway` until 0.20.0). Call your API through `TransportClient(ref.watch(authTransport))`
  (`fespalier_http`, an `http.Client`) or `TransportAdapter(ref.watch(authTransport))` (`fespalier_dio`, a Dio adapter).
  Watch `authUserId` in a `data.dart`: a user change reloads it, a renewal does not.
- **A backend** is `AuthBackend`: `name`, `scheme`, `authenticator` (a `RequestAuthenticator`: `headers` for every send,
  `judge` returning `Accept`, `Resend`, `Renew`, `StepUp` (since 0.25.0) or `SessionEnded`), `readCredential`,
  `renewAhead`, `signIn`, `renew` (was `refresh`), `stepUp` (since 0.25.0; the default throws `UnsupportedError`),
  `check`, `signOut` and `discard`. A starter over a JSON API is in `references/auth-package.md`.
- **Step-up (since 0.25.0).** A 401 with `WWW-Authenticate: Bearer error="insufficient_user_authentication"` (RFC 9470,
  `acr_values` and `max_age` optional) is a `StepUp(StepUpChallenge)` verdict, not a `Renew`: the session asks the user
  once (`AuthSessionNotifier.stepUp`, shared by concurrent requests; `OidcBackend` signs the same user in again with
  `acr_values` / `max_age`, or `prompt=login`), then sends the request **once** more. A second refusal is the answer; a
  cancel or a provider refusal keeps the session and returns the 401. Mark background work
  `Authorizer.stepUpAttribute: false`, or run it inside `Authorizer.unattended(...)` when the client cannot set
  attributes (a generated CrateStack call), so it never prompts. A device session steps up per request instead: the
  same request signed again with the user-present key. A route that needs a recent sign-in uses
  `requireFreshAuth(ref, uri, maxAge:, signIn:, reauthenticate:)`, and the re-proof page's own guard
  `redirectIfFreshAuth(ref, maxAge:, from:)`; the time is `AuthSession.authenticatedAt` (`auth_time`, else the sign-in or
  step-up time; null, too old, for a session stored before 0.25.0). Details and code:
  [`references/auth-package.md`](references/auth-package.md#step-up-and-recent-sign-ins).
- **Tests:** `fakeAuth(signedInAs: ..., transport: FakeTransport(...))` from `package:fespalier_auth/testing.dart` is the
  `overrides` of `pumpRouter`; see [`fespalier-testing`](../fespalier-testing/SKILL.md).
- Never log or put a credential, an id or an e-mail in an error or a telemetry attribute: the package's own
  `toString`s hide them.
- **With `fespalier_cratestack`** (since 0.10.0): `crateStackScope.overrideWith((ref) => ref.watch(authUserId))`, and a
  sign-out calls `ref.read(crateStackAccount).clear()` **before** `signOut()`, whose state flips synchronously (or
  `clear(scope: id)` after). A `401` keeps a queued intent's key ([`fespalier-offline`](../fespalier-offline/SKILL.md)).

- **OpenID Connect and Keycloak are the `fespalier_oidc` package** (since 0.21.0; `package:fespalier_auth/oidc.dart` until
  0.20.0). `OidcBackend(transport: ...)`: code flow with PKCE for a public client, Keycloak's endpoints and roles,
  refresh-token rotation, a `TokenCredential` and a `BearerAuthenticator`. Firebase and Supabase are **recipes**, not
  packages. [`references/auth-backends.md`](references/auth-backends.md) has the code and what was read from a live
  Keycloak 26.8.0.
- **A replay after a verdict is marked** (`transportReplayKey` in `TransportRequest.attributes`) and keeps the request's
  abort trigger. **Never put a retrier under the session transport**: it re-sends the same DPoP proof, or the same
  signature, and the server refuses it. Put `RetryClient` or `dio_smart_retry` above it. The whole chain's order is in
  [`docs/transport.md`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#decorators-and-their-order).

- **Device-bound tokens are `fespalier_keypair_dpop`** (with `fespalier_oidc` and `fespalier_keypair`, the **same `url`
  and `ref`** for all; it was `fespalier_sign_keypair` until 0.20.0): `OidcBackend(proof: DpopProof.device())` signs every
  token call and API request with a key in the Secure Enclave or the AndroidKeyStore, or on the web the browser's
  non-extractable key (since 0.21.0; **UNCHECKED in CI**, run by hand in Chrome only), and the server binds the tokens to it
  (DPoP, RFC 9449). **`DpopProof.device()` throws `DpopUnavailable` on Windows and Linux** unless `fallback:
DpopFallback.software` (a key in memory) or `DpopFallback.bearer` (no DPoP) is given. Sign-out deletes the key. Keycloak
  sends no nonce and no `Date`, so a wrong device clock is `DPoP proof is not active`: set the clock.
  [`references/auth-dpop.md`](references/auth-dpop.md).
- **No token at all: `fespalier_sign_keypair`** (since 0.21.0; it held DPoP until 0.20.0). `DeviceAuthBackend` makes a
  session of an enrolled device key: enrolment is signing in (`beginEnrolment`, then `signIn(CompleteEnrolment(...))`, both
  unsigned), every request carries `X-Attestation` and `X-Signature` over its method, path, query and exact body bytes
  (**a streamed body cannot be signed**: `ArgumentError`), renewal is a re-attestation, `webankRefusals` sorts a 401 or 403
  into renew, `keyLost` or `revoked`, and a request asks for the user-present key (a biometric prompt) with
  `DeviceSigner.roleAttribute`, or, since 0.25.0, gets it when the server answers a step-up refusal (CrateStack's
  `@authn`): `DeviceSigner` signs that request again with the user-present key, once, never for unattended work, and a
  cancelled prompt leaves the 401. You write the `DeviceAuthServer` (five methods over your endpoints); the secure-element
  parts are **UNCHECKED on a device**. [`references/auth-device-sessions.md`](references/auth-device-sessions.md).

[`references/auth-package.md`](references/auth-package.md) has the pieces, a compiled starter (a backend over
a JSON API, the guards, the sign-in form, an API call and its tests) and every behaviour above in detail;
`examples/auth` is the running version (guards, form, renewal, restore, Keycloak realm). Its messages are in
[`fespalier-troubleshooting`](../fespalier-troubleshooting/SKILL.md) (its `diagnostics-auth.md` page).

## Feature flags (`fespalier_flags`, since 0.9.0)

fespalier's core has **no flag feature**; the `fespalier_flags` package (a git dependency next to fespalier, **same `url`,
same `ref`**) is a guard with a source of values. It adds no dependency beyond fespalier, no timer and no polling, and
changes no generated code.

```dart
// flags.dart
const labs = BoolFlag('labs');

// app/labs/guard.dart: /labs is there while the flag is on; a nav.dart beside it is hidden while it is off
GuardResult guard(Ref ref) => flagGuard(ref, labs, orElse: const HomeRoute().location);

// app/startup.dart
Future<List<Override>> startup() async => [
  flagSource.overrideWithValue(const ConstFlags({'labs': bool.fromEnvironment('LABS')})),
];
```

- **A flag is synchronous**: `ref.watch(flag(labs))` is a `bool`, never an `AsyncValue` or a `Future`, and a flag that is
  not known yet is its **fallback**. So the guard stays sync, the first frame is not blank, and menus (which run guards)
  hide the entry for free.
- **One `guard.dart` per folder**: compose with `??` (`flagGuard(...) ?? requireSignedIn(...)`).
- **Never call a vendor's async API in a guard** (PostHog's `isFeatureEnabled` is a `Future`: the entry turns pending and
  the first frame is blank). Put the value behind a `FlagSource`.
- **`follow: false` for a flow**: with the default, turning the flag off on the page takes the user off it; a
  pushed page goes too (since 0.21.0).
- **A guard that redirected stays subscribed until the next navigation**, so a flag's subscription outlives the page it
  gated by one navigation (a test pins it). A guarded page under a pushed page that has no guard reacts only when uncovered.
- **A cold deep link before the source is ready sees the fallback**: await the vendor's local load in `startup()`, or
  wrap a network-first vendor in `AsyncFlags` (the app's own `.timeout()` is the only timer).
- **Without an override every flag is its fallback.** A flag that is "always off" is no override in `startup()`, or a key
  typo (`FakeFlags.strict` in tests).
- **Not built:** a `route.dart` constant for a flag, vendor packages, a DevTools flag panel.

[`references/feature-flags.md`](references/feature-flags.md) has the package in full and a compiled starter (the route, the
guard, the menu entry, `startup()` and the tests); [`references/flag-sources.md`](references/flag-sources.md) has the vendor
bridges as compiled recipes (Firebase Remote Config, LaunchDarkly, PostHog, GrowthBook, an OpenFeature sketch). `examples/features` has `/labs` behind a flag. The tests use
`FakeFlags` from `package:fespalier_flags/testing.dart` ([`fespalier-testing`](../fespalier-testing/SKILL.md)); the run-time
messages are in [`fespalier-troubleshooting`](../fespalier-troubleshooting/SKILL.md) (its
`diagnostics-flags-storage-network.md` page).

## Biometric unlock (since 0.13.0)

`package:fespalier_biometrics` puts a route behind a fingerprint or a face. **A guard never prompts**: a guard runs again
whenever something it watches changes, and one that showed the platform's sheet would show it again each time.
`requireUnlocked(ref, uri, unlock: (from) => UnlockRoute(from: from), maxAge:)` reads the unlock state and redirects,
synchronously; the unlock page beside the guarded folder calls `ref.read(biometricUnlock.notifier).unlock(reason)`
(single-flight, never throws) and goes to `returnTo(from)`; `withBiometrics(ref, reason, action, maxAge:)` makes an
action ask again and throws `BiometricDeclined`. The app gives a `BiometricPrompt` in `startup()`
(`biometricPrompt.overrideWithValue(...)`); `local_auth` is a recipe, not a dependency, because its 2.x and 3.x cannot
share one source. The state relocks when the app comes back from the background (core's `appShowSignal`, not a notification shade or
the platform's sheet) at least `BiometricPolicy.resumeGrace` after the unlock, with no timer and no listener; the
default 10 s grace is a security trade-off the reference states; `maxAge` is checked at the next navigation, never by
itself. Since 0.19.0 `BiometricPolicy(idleTimeout:)` locks after that long without a touch: `BiometricActivity` in
`MaterialApp.router(builder:)` records touches and keys and absorbs (and locks on) the first touch after the limit, and the
app fires `biometricIdleTicker` from its own `Timer.periodic` (at most `idleTimeout / 4`, paused while hidden; the package
has no timer). `requireUnlocked` and `isFresh` treat an idle unlock as locked at the next navigation. Telemetry is `fespalier.biometrics.prompt` with `fespalier.biometrics.result`. Since 0.19.0 a secret can be kept behind the biometric: the app gives a `BiometricSecrets` (`biometricSecrets.overrideWithValue(...)`; `flutter_secure_storage` is a compiled recipe, not a dependency) and `ref.read(biometricUnlock.notifier).readSecret(key, reason)` answers `SecretFound`, `SecretMissing` or `SecretRefused(outcome)`; **the keystore gates the item** (a value hidden behind `unlock()` in Dart is readable by code that skips the guard), the read is one sheet at a time (it waits for an `unlock()` sheet; two reads of one key share one), **a read does not unlock the app**, and the value goes to the caller only (`fespalier.biometrics.secret` telemetry: constants, never the key, value or reason). Since 0.19.0 `BiometricLockScreen` (`package:fespalier_biometrics/material.dart`, the one Material library) is
the unlock page's body: its button prompts on a tap and never otherwise, it shows the `failed` and `lockedOut` words, and
an `unavailable:` builder replaces the button on a device that cannot ask. To ask as the page opens, use the unlock
folder's `observe.dart` `onEnter` (after the frame), never `build`. Never call `unlock()`
from `build` or a guard; never put `requireUnlocked` on the unlock page.

[`references/biometrics.md`](references/biometrics.md) has the package in full and a compiled starter;
[`references/biometric-lock-screen.md`](references/biometric-lock-screen.md) the lock screen with the `onEnter` auto-prompt;
[`references/biometric-secrets.md`](references/biometric-secrets.md) the `flutter_secure_storage` recipe for secrets;
[`references/biometric-prompts.md`](references/biometric-prompts.md) (`local_auth` 3.x) and
[`references/biometric-prompts-local-auth-2.md`](references/biometric-prompts-local-auth-2.md) (2.x, with
`useErrorDialogs: false`) are the prompt recipes. The tests use `FakeBiometricPrompt` and `FakeBiometricSecrets` from
`package:fespalier_biometrics/testing.dart` ([`fespalier-testing`](../fespalier-testing/SKILL.md)).

## Where to read more

| Need                                                                                                                                      | Reference                                                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Every guard and redirect rule, compiled samples, `returnTo` details                                                                       | [`references/guards-and-redirects.md`](references/guards-and-redirects.md)                                                                                           |
| Session provider, sign-in/out, guards that re-run, async guards                                                                           | [`references/auth-patterns.md`](references/auth-patterns.md)                                                                                                         |
| `fespalier_auth` (since 0.9.0): restore, guards, renewal, the session transport, tests                                                    | [`references/auth-package.md`](references/auth-package.md)                                                                                                           |
| OpenID Connect (`fespalier_oidc`), Keycloak, Firebase, Supabase, your own API, dio                                                        | [`references/auth-backends.md`](references/auth-backends.md)                                                                                                         |
| Device-bound tokens: DPoP (`fespalier_keypair_dpop`), proofs in tests                                                                     | [`references/auth-dpop.md`](references/auth-dpop.md)                                                                                                                 |
| Device-signed sessions, no token (`fespalier_sign_keypair`, since 0.21.0): enrolment, a signature per request, user-present keys          | [`references/auth-device-sessions.md`](references/auth-device-sessions.md)                                                                                           |
| Feature flags (since 0.9.0): `flagGuard`, flag providers, `FakeFlags`                                                                     | [`references/feature-flags.md`](references/feature-flags.md)                                                                                                         |
| Flag sources (since 0.9.0): Remote Config, LaunchDarkly, PostHog, GrowthBook                                                              | [`references/flag-sources.md`](references/flag-sources.md)                                                                                                           |
| Biometric unlock (since 0.13.0): `requireUnlocked`, `unlock()`, `withBiometrics`, relock, idle lock, `BiometricLockScreen` (since 0.19.0) | [`references/biometrics.md`](references/biometrics.md)                                                                                                               |
| `BiometricLockScreen` with an `onEnter` auto-prompt (since 0.19.0)                                                                        | [`references/biometric-lock-screen.md`](references/biometric-lock-screen.md)                                                                                         |
| `local_auth` as a `BiometricPrompt` (3.x, and 2.x for Flutter before 3.38)                                                                | [`references/biometric-prompts.md`](references/biometric-prompts.md), [`references/biometric-prompts-local-auth-2.md`](references/biometric-prompts-local-auth-2.md) |
| `flutter_secure_storage` as `BiometricSecrets`: a secret behind the biometric (since 0.19.0)                                              | [`references/biometric-secrets.md`](references/biometric-secrets.md)                                                                                                 |
| Testing a guarded route                                                                                                                   | `fespalier-testing`                                                                                                                                                  |
| An `fsp` error on a guard or redirect                                                                                                     | `fespalier-troubleshooting`                                                                                                                                          |
