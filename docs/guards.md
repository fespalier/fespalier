# Guards

```dart
// lib/app/(members)/guard.dart: guards /inbox, /admin and everything else in the group
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

`guard.dart` exports `GuardResult guard(Ref ref, {…})`. It returns a location to redirect to, or `null` to let the navigation through, and may be async. It guards every route at and below its folder; the folder needs no `page.dart`, so put one in a `(group)` or at the root to cover a whole section. A `guard.dart` with no `page.dart` or `redirect.dart` at or below its folder is a warning.

**It runs again when what it watches changes** (since 0.5.0). `ref.watch` a provider in the guard and, when that provider changes and the answer is now different, the router runs the redirects again. Signing out moves you to the login page from whatever member page you were on, with no refresh code of your own.

- Nothing is wired up: it works for `AppRoutes.router()` and for a router of your own built from `AppRoutes.mount()`, with no `refreshListenable`.
- The login page is not under that guard, so signing in is the login page's to navigate (`returnTo`), unless it has a guard of its own that watches the session.
- `ref.read` is for what must be the current value when you navigate; it never changes the answer later. A guard that returns the same answer after a change does nothing.
- An async guard watches the same way, through a provider's `.future`:

  ```dart
  Future<String?> guard(Ref ref, {required Uri uri}) async =>
      await ref.watch(currentUser.future) == null
          ? LoginRoute(from: uri.toString()).location
          : null;
  ```

**Rules and behaviour.**

- **What it costs.** Return synchronously when you can: a guard that needs no `await` should not be `async` (nor return `Future.value(...)`). It then answers in the same frame as the navigation, and the first frame at boot (a cold deep link too) already shows the page. Any `Future`, even a completed one, costs the router a frame, and the first frame is blank. Each navigation runs the guard in a fresh `autoDispose` provider, so what it `ref.watch`es is shared with the rest of the app and fetched once. The guard runs again after a change and again when the router asks, so keep it cheap (a guard signing out runs twice; the data providers it watches are not fetched twice).
- **When it stops watching.** The guard of the location the router shows keeps watching. It is dropped when a navigation ends on a location that does not run it, and when the router or the app goes. A guard that redirected is kept until the next navigation commits. A guarded page _under a pushed page_ does not react until you pop back to it (popping runs the guard again). Don't call `ref.keepAlive()` in a guard: it keeps one provider alive per navigation.
- **If it throws.** A guard that throws never moves the router: an error on a navigation reaches go_router like any redirect's, and an error on a later run keeps the page you are on until the next navigation. The guard's provider does not retry.
- **`ProviderContainer`.** A guard may still take `ProviderContainer c` first (`c.read(session)`): it is read once per navigation and never runs again by itself. Taking a `WidgetRef` is an error ("a guard runs outside the widget tree: take `Ref`").
- **Order.** Guards run outermost first, and the first one to return a location wins. A folder with a page and its own guard keeps it for that page and everything nested in it; guards above run first. A route with [`nest = false`](routing.md#a-sibling-with-a-compound-path) is not nested in the page above it, and still gets that page's guard, after the ones above it.
- **Parameters.** The `Ref` comes first, then named parameters:
  - `uri`: the requested location, a `Uri`.
  - `extra`: see [Typed `extra`](navigation.md#typed-extra).
  - The segments of the guard's own folder and the ones above it (`{required String shop}`), typed like everywhere else. A guard above `$id` can't ask for `id`: that's an error at the parameter.
  - Query parameters, optional and nullable (`String? ref`). They stay the guard's own and don't become fields of the typed routes below it (unless the guard sits next to a `page.dart`, where they are the page's).

**What gets generated.** Each page's `GoRoute` gets a `redirect` that calls, in order, the guards of the page-less folders above it and then its own (`refGuard(context, 'g8@3', (ref) => _i8.guard(ref, uri: state.uri))`, the string naming the guard on that route; since 0.7.0 each call sits in a `traceGuard` that returns it unchanged, for the [DevTools extension](devtools.md)). Nested pages go through their parent's `redirect`, so no guard runs twice, and a route with `nest = false` carries its parent page's guard itself. There is no redirect on `ShellRoute` or `StatefulShellRoute`: go_router runs a matched route's redirect for deep links and for navigation inside a shell, tabs included.

When a path has a segment that doesn't parse (`/products/abc`), not-found is shown, and a guard that asks for segments or query parameters is skipped, since it has nothing to read. A guard that asks for neither (only `uri`, `extra`, or nothing) still runs, so it can redirect `/products/abc` to login.

## `redirect.dart`

A folder can hold `redirect.dart` instead of `page.dart`. It exports `String redirect({…})` (or `Future<String>`) returning the location to go to, and the route only redirects: no widget, no builder.

```dart
// lib/app/old-products/$id/redirect.dart: /old-products/3 → /products/3
String redirect({required int id}) => ProductRoute(id: id).location;

// ...or, reading a provider (a redirect's `ref.watch` runs once, it does not re-run)
String redirect(Ref ref, {required int id}) =>
    ref.read(catalog).contains(id) ? ProductRoute(id: id).location : const HomeRoute().location;
```

It takes the same parameters as a guard, except that the first one is optional: put `Ref ref` first if you need providers (since 0.5.0; `ProviderContainer c` also works).

- It runs once per navigation and does not watch: a redirect route never stays on screen, so there is nothing to run again.
- Segments are typed like anywhere else, so `/old-products/abc` shows not-found.
- It gets a typed route, named after its path (`OldProductsIdRoute(id: 3)`), so links to the old URL stay typed; query parameters it asks for are its fields.
- It takes part in route order and unreachable checks like a page, inherits the guards above it, and can sit next to a `guard.dart`, which runs first.
- A folder has a `page.dart` or a `redirect.dart`, not both, and a tab layout's own folder can't hold a `redirect.dart`. Routes in subfolders sit beside a redirect route rather than inside it, since anything inside would redirect too.

## Sending people back

```dart
LoginRoute(from: uri.toString()).location   // /login?from=%2Finbox%3Ffolder%3Dsent
```

A guard that redirects to a login page can pass along where the user was going. Ask for `Uri uri` (the requested location, query included) and put it in the login route's query, as above. `login/page.dart` takes it as a query parameter (`this.from`, a `String?`), and when the user is done it calls `returnTo`:

```dart
context.go(returnTo(from));                  // from if it's a location in the app, else '/'
```

`returnTo(from, fallback: '/home')` only lets an absolute path through: `https://…`, `//host` and the like fall back, so a crafted `?from=` can't send people off your app. Both `uri` and the typed routes include the mount prefix when the tree is mounted with `at:`.

## Feature flags: fespalier_flags

Since 0.9.0. A feature flag is a value the app asks for by name and that a server, a vendor SDK or a build can change: show `/labs` to some users, move `checkout` to its second version. `package:fespalier_flags` gives guards a source of values. A flag is a provider that answers **at once** (never an `AsyncValue`, never a `Future`), so a guard that watches one stays synchronous, and a menu entry behind it follows the flag because [menus run guards](layouts.md#menus-and-breadcrumbs-navdart). It adds no dependency beyond fespalier, no timer and no polling.

Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_flags:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_flags
      ref: v0.15.0
```

<!-- x-release-please-end -->

Declare each flag once, `const`, gate a route with `flagGuard` in its `guard.dart`, and read a flag anywhere that has a `Ref` or a `WidgetRef`:

```dart
// lib/flags.dart
const labs = BoolFlag('labs');
const checkoutV2 = BoolFlag('checkout_v2');
const pageSize = IntFlag('page_size', fallback: 20);

// lib/app/labs/guard.dart: /labs is there while the flag is on
GuardResult guard(Ref ref) => flagGuard(ref, labs, orElse: const HomeRoute().location);

// a widget, a provider, a guard: the value is there at once
final size = ref.watch(flag(pageSize));
```

`BoolFlag` is off unless the source says otherwise (its `fallback` is `false`); `StringFlag`, `IntFlag` and `DoubleFlag` have a required `fallback`. A flag is its **fallback** whenever the source has no value for its key, has one of another type, throws, or has not started yet, so a flag is never loading. Two declarations with the same type, key and fallback are the same flag.

A `nav.dart` beside the `guard.dart` needs nothing else: while the flag is off the guard refuses the entry, and a refused entry is hidden (`NavRefused.hide`, the default; `whenRefused: NavRefused.disable` greys it out instead).

**Patterns.**

- **A new route behind a flag:** `lib/app/checkout-v2/guard.dart` is `flagGuard(ref, checkoutV2, orElse: const CartRoute().location)`. A whole section: the guard goes in a `(group)` or in the section's folder, as any guard.
- **The old URL goes to the new one while the flag is on:** `checkout/guard.dart` is `flagGuard(ref, checkoutV2, whenOff: true, orElse: const CheckoutV2Route().location)`.
- **The same URL, two pages:** no guard; the page switches: `ref.watch(flag(checkoutV2)) ? const CheckoutV2() : const CheckoutV1()`.
- **A flag and a sign-in:** a folder has one `guard.dart`, so compose with `??`. `flagGuard` returns a `String?`, synchronously: `flagGuard(ref, labs, orElse: '/') ?? (ref.watch(session) ? null : LoginRoute(from: uri.toString()).location)` (with [`fespalier_auth`](auth.md): `?? requireSignedIn(ref, uri, signIn: ...)`).
- **A flow that must not be pulled from under the user** (a checkout): `flagGuard(ref, checkoutV2, orElse: '/', follow: false)` reads the flag once per navigation (`ref.read`): the page stays open when the flag turns off, the next navigation applies it, and a menu does not follow.

**Live updates.** A source can send an event when values change (`FlagSource.changes`: `FlagsChanged({'labs'})` names the keys, `FlagsChanged.all()` means any). `fespalier_flags` listens with **one subscription per `ProviderContainer`**, opened when the first flag is watched and cancelled when the last watched flag goes, and reads again only the watched flags the event names. A guard, a menu or a widget runs again only when the value it reads **differs**, so a flag that turns off on `/labs` takes the app to `orElse` in the next frame and a menu entry under it hides, with no navigation. Nothing in the package polls or starts a timer; a vendor's own streaming or polling runs inside its SDK, by its settings.

**What to know.**

- **A guard that redirected stays subscribed until the next navigation**, so a flag's subscription can outlive the page it gated by one navigation: a cold deep link to `/labs` with the flag off lands on `/`, and the flag is still listened to until the user goes somewhere else.
- **A guarded page under a pushed page** does not react until it is uncovered (the rule of every guard).
- **A cold deep link before the source is ready** sees the fallback, so a guard sends it to `orElse`: await the vendor's local load in `startup()` (below).
- **Never call a vendor's async API in a guard.** PostHog's `isFeatureEnabled` is a `Future`: the guard answers a `Future`, the menu entry turns pending and the first frame is blank. Copy the value into a [`FlagSource`](#where-flag-values-come-from) and read that.
- **`follow: true` (the default) takes a user off a page** when the flag turns off mid-flow. Use `follow: false` for a flow.
- **Each change re-reads the watched flags the event names.** Vendors that count evaluations (LaunchDarkly) or track exposures (GrowthBook) see those reads; a keyed `FlagsChanged` keeps them to the keys that changed.

**Not built.** A `route.dart` constant (`const flag = 'checkout_v2'`), vendor **packages** (each bridge is 15 to 40 lines of mapping, so they are recipes, below), and a DevTools panel for flag values.

### Where flag values come from

`startup()` returns the source, once: `flagSource.overrideWithValue(source)`. Without one, `flagSource` is `const ConstFlags()`: every flag is its fallback.

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  flagSource.overrideWithValue(const ConstFlags({'labs': bool.fromEnvironment('LABS')})),
];
```

A `FlagSource` is four synchronous typed reads (`boolValue(key, fallback)`, `stringValue`, `intValue`, `doubleValue`) and `Stream<FlagsChanged>? get changes`. Every read must answer **from memory**: guards and menus call it, so never from the network, a file or a platform channel. A read that throws is the flag's fallback (printed in debug).

| Source               | What it is                                                                                                                                      |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `ConstFlags({...})`  | Fixed values, or `--dart-define`d ones. `changes` is `null`. A bool reads a `bool`, a double any `num`; a value of another type is the fallback |
| `AsyncFlags(future)` | A source that is not ready at start: reads come from `meanwhile` until the future completes, then one `FlagsChanged.all()`                      |
| A vendor bridge      | Your own `FlagSource` over the vendor's SDK: a recipe, below                                                                                    |
| `FakeFlags({...})`   | For tests: [Testing flagged routes](#testing-flagged-routes)                                                                                    |

**Initial values, with no timer.** `startup()` awaits only what is **local**: Remote Config's `ensureInitialized()` and `activate()` (the values the previous session fetched), LaunchDarkly's construction, PostHog's `setup()` and a read of the app's keys from the native SDK's cache. From the first frame every read is a synchronous call into the vendor's memory.

- A vendor whose start waits for the network (GrowthBook past its cache's TTL, LaunchDarkly's `start()` on a first launch, which "may not complete until ... the device leaves airplane mode") goes in `AsyncFlags(start(), meanwhile: ...)`: the fallbacks (or the app's last known values) until the `Future` completes, then one `FlagsChanged.all()`.
- An app that must see remote values before its first frame awaits the vendor in `startup()` with a `.timeout()` of its own if it wants one: that timer is the app's choice, and tests never reach it (they override `flagSource`).

**Recipes.** Firebase Remote Config, LaunchDarkly, PostHog and GrowthBook have a recipe, about 15 to 40 lines each (a class that `implements FlagSource` and a `startup()` that returns it), in [`skills/fespalier-guards/references/flag-sources.md`](../skills/fespalier-guards/references/flag-sources.md). They are not packages because no fespalier logic is left in them. **OpenFeature** is the common interface to converge on, but its Dart SDK is a beta, so it is not adopted; `FlagSource` mirrors its typed reads and its configuration-changed event, and a bridge is about 25 lines.

### Testing flagged routes

`FakeFlags` (in `package:fespalier_flags/testing.dart`) is a `FlagSource` that holds values in memory. Give it to `pumpRouter` as an override, or to the setup file of `fsp test`:

```dart
testWidgets('labs is there with the flag on, and goes with it', (tester) async {
  final flags = FakeFlags({'labs': true});
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/labs'),
    overrides: [flagSource.overrideWithValue(flags)],
  );
  expect(currentLocation(tester), '/labs');

  flags.set('labs', false);   // delivered synchronously
  await tester.pump();        // one frame: the guard ran again, the router moved
  expect(currentLocation(tester), '/');
});
```

```dart
// test/routes/setup.dart: `fsp test` tests a flagged route instead of skipping it
List<Override> overrides(String pattern) => [
  flagSource.overrideWithValue(FakeFlags({'labs': pattern == '/labs'})),
];
```

- **`set(key, value)`** sends `FlagsChanged({key})` before it returns, `setAll({...})` one event for several keys, and a `null` value removes the key. Call them from the test body, not while a widget builds.
- **`FakeFlags.strict({...})`** throws a `StateError` for a key it lacks or a value of another type, and reports it to `FlutterError.reportError`, so a typo in a key fails a `testWidgets` instead of reading the fallback.
- **`listenerCount`** is how many listen to its changes: `0` once nothing watches a flag.
- Without an override, every flag is its fallback, so existing tests of an app that adds a flag see the flag off.

## Biometric unlock: fespalier_biometrics

Since 0.13.0. A route behind a fingerprint or a face (an orders list, a wallet, a secret) is a guard with one rule that is easy to break: **a guard never prompts.** A guard runs again whenever something it watches changes, on every navigation and on a cold deep link, so a guard that showed the platform's sheet would show it again each time. `package:fespalier_biometrics` splits the job in three: a state (`biometricUnlock`: `Locked`, `Unlocking`, `Unlocked(at)`), a guard (`requireUnlocked`) that reads the state and redirects to the app's unlock page, and one function that prompts, `unlock()`, which the unlock page or an action calls and which is single-flight. It depends on fespalier and `package:clock`, starts no timer and adds no listener.

Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_biometrics:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_biometrics
      ref: v0.15.0
```

<!-- x-release-please-end -->

The platform check is **not** in the package. `local_auth` 2.x and 3.x cannot share one source (2.x takes `AuthenticationOptions` and defaults `useErrorDialogs` to native dialogs, 3.x takes named parameters, throws `LocalAuthException` and needs Flutter 3.38 or newer), so the package defines a `BiometricPrompt` (`isAvailable()` and `authenticate(reason)`, returning a `BiometricOutcome`: `success`, `cancelled`, `failed`, `unavailable`, `lockedOut`) and each `local_auth` is a recipe of about 25 lines in the fespalier-guards skill (`biometric-prompts.md` for 3.x, `biometric-prompts-local-auth-2.md` for 2.x). It shows the platform's own sheet and never a Flutter dialog. The app gives its prompt in `startup()`:

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  biometricPrompt.overrideWithValue(const LocalAuthPrompt()), // your BiometricPrompt
];
```

Until it does, reading `biometricPrompt` throws a `StateError` that names the override.

### The unlock page

```dart
// lib/app/vault/guard.dart: guards /vault and everything below it
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireUnlocked(ref, uri, unlock: (from) => UnlockRoute(from: from));
```

`requireUnlocked` returns `null` while the app is unlocked and the unlock page's location (with `from`, the `uri` it was going to) otherwise. It is synchronous, so a cold deep link shows the unlock page in its first frame. The unlock page sits **beside** the guarded folder (a guard on it would redirect to itself), asks, and goes back:

```dart
// lib/app/unlock/page.dart
FilledButton(
  onPressed: () async {
    final outcome = await ref.read(biometricUnlock.notifier).unlock('Unlock your vault');
    if (outcome == BiometricOutcome.success && context.mounted) context.go(returnTo(from));
  },
  child: const Text('Unlock'),
)
```

- **`unlock(reason)` is single-flight and never throws.** While a sheet is up, a second call (a double tap, two buttons) gets the same `Future`. A prompt that throws is `BiometricOutcome.failed`. Anything but a success leaves the state as it was before the call.
- **The guard watches only whether the app is unlocked.** A prompt coming and going (`Unlocking`) and a second `Unlocked` stamp do not run it again, so a re-run is never a re-prompt; a `lock()` or a relock does run it, and the router leaves the page. A prompt over an unlocked page (an action's) does not send the page away: `Unlocking` carries whether the app was unlocked, and the guard keeps its answer.
- **`maxAge:`** also requires the unlock to be younger than that by `package:clock`. It is evaluated when the guard runs or when `isFresh(maxAge:)` is asked, that is at the next navigation (or any re-run of the guard), never by itself: there is no timer, so a page left open stays open.
- **`biometricAvailable`** is a `FutureProvider<bool>` for the unlock page, which can offer "Use your passcode" instead of a button that cannot work.

### Actions that ask again

```dart
// lib/app/vault/reveal/action.dart
Future<String> action(Ref ref, {required String input}) =>
    withBiometrics(ref, 'Show the card number', () => loadCardNumber(ref));
```

`withBiometrics(ref, reason, action, {maxAge})` is for the write or the read that must not run on a borrowed phone. It prompts unless the unlock is younger than `maxAge` (the default, `Duration.zero`, asks every time), runs `action` after a success, and throws `BiometricDeclined(outcome)` otherwise, which an [action](actions.md)'s state shows like any failure. A success also counts as an unlock for the guards.

### Relock when the app comes back

`BiometricUnlock` watches core's `appShowSignal` (since 0.13.0: `AppLifecycleListener.onShow`, the app is visible again **after it was hidden**), so a return from the background runs its `build` again, and it goes back to `Locked` when that return is at least `BiometricPolicy.resumeGrace` after the unlock. The guard then sends the person to the unlock page. It adds no listener of its own and no timer (`appShowSignal` is core's one `AppLifecycleListener`, kept alive while the notifier is). It is not `appResumeSignal`: an iOS notification shade or Control Center, a call banner and the platform's own biometric sheet make the app inactive and back, and none of them is a return from the background.

```dart
// lib/app/startup.dart: every return from the background locks
biometricPolicy.overrideWithValue(const BiometricPolicy(resumeGrace: Duration.zero)),
```

**The default grace is 10 seconds, and that is a trade-off.** The platform's sheet and some system overlays can hide the app and show it just after the sheet's answer, so with `Duration.zero` the sheet could undo its own unlock. The price is a window of 10 seconds after each unlock in which putting the app in the background and bringing it back asks nothing: on a borrowed phone, that is the time someone has. An app that guards something worth more sets a shorter grace, or zero, and checks on a device that the platform's sheet does not lock it. Switching apps through the iOS app switcher without the app being hidden is not a return either. A return while a sheet is up never drops the prompt, and one past the grace still relocks when the sheet ends without a success (`persistAcrossBackgrounding`). A clock set back counts as expired, so winding the clock back does not keep an unlock. Locking does not clear the data providers that loaded a secret; invalidate them when `biometricUnlock` goes to `Locked` if that matters.

Each prompt is reported as one `fespalier.biometrics.prompt` operation with `fespalier.biometrics.result` set to the outcome's name, to an installed [telemetry](observability.md#telemetry) sink. Never the reason text.

### Testing an unlock

`package:fespalier_biometrics/testing.dart` has `FakeBiometricPrompt` (outcomes from a queue, a `prompts` count, `reasons`, `hold()` and `release()` for a sheet that is up) and `biometricTestOverrides(prompt, policy:)`, the overrides for `pumpRouter` or a `ProviderContainer`:

```dart
testWidgets('locked: the vault sends the person to unlock, and nothing is prompted', (tester) async {
  final prompt = FakeBiometricPrompt();
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/vault'),
    overrides: biometricTestOverrides(prompt),
  );
  expect(currentLocation(tester), startsWith('/unlock'));
  expect(prompt.prompts, 0);

  await tester.tap(find.text('Unlock'));
  await tester.pumpAndSettle();
  expect(currentLocation(tester), '/vault');
  expect(prompt.prompts, 1);
});
```

Move time with `withClock(Clock.fixed(...))` for `maxAge` and the grace, and fire a return from the background with `container.read(appShowSignal.notifier).fire()` (the real signal needs a `WidgetsBinding`, which `biometricTestOverrides` swaps for a plain one; with a binding, `handleAppLifecycleStateChanged` through `hidden` and back is the real thing).
