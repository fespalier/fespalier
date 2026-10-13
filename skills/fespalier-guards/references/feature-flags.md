# `fespalier_flags`: feature flags

Since 0.9.0. fespalier's core has no flag feature: no file kind, no `fespalier:` key, no `fsp` command, and `app.g.dart`
is the same bytes. `package:fespalier_flags` is [a guard](guards-and-redirects.md) with a source of values: a flag is a
provider that answers **at once**, so a guard that watches one stays synchronous, and a menu entry behind it follows the
flag because menus run guards. It adds no dependency beyond fespalier, no timer and no polling.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_flags:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_flags
      ref: <the same tag>
```

(That block is a fragment, not a sample: pub resolves the pair only at a release tag. `docs/guards.md` has the
annotated one.) A mismatch fails like the one for `fespalier_auth`: give both the same `url` (no `.git`) and `ref`.

## What it is made of

| Piece                                                  | What it does                                                                                                                                                                                         |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BoolFlag`, `StringFlag`, `IntFlag`, `DoubleFlag`      | A flag declaration: the `key` at the source and a `fallback`. Declare each `const`; two with the same type, key and fallback are one flag. `BoolFlag`'s fallback is `false`, the others' is required |
| `flag(f)`                                              | `ref.watch(flag(labs))`: the value, a `bool`, `String`, `int` or `double`, **never** an `AsyncValue` or a `Future`. An `autoDispose` provider per flag                                               |
| `flagSource`                                           | The `Provider<FlagSource>` every flag reads: `flagSource.overrideWithValue(source)` in `startup()`. Without an override it is `const ConstFlags()`: every flag is its fallback                       |
| `FlagSource`                                           | Four synchronous typed reads, `boolValue(key, fallback)`, `stringValue`, `intValue`, `doubleValue`, and `Stream<FlagsChanged>? get changes`                                                          |
| `FlagsChanged({'labs'})`, `FlagsChanged.all()`         | A `changes` event: the keys that changed, or any                                                                                                                                                     |
| `ConstFlags({...})`                                    | Fixed values, or `--dart-define`d ones. A bool reads a `bool`, a double any `num`; a value of another type is the fallback. `changes` is `null`                                                      |
| `AsyncFlags(future, meanwhile: ...)`                   | A source that is not ready at start: reads come from `meanwhile` until the future completes, then one `FlagsChanged.all()`                                                                           |
| `flagGuard(ref, gate, orElse: ..., whenOff:, follow:)` | For a `guard.dart`: `null` while the flag is on (or off with `whenOff`), `orElse` otherwise. A `String?`, so it composes with `??`                                                                   |
| `package:fespalier_flags/testing.dart`                 | `FakeFlags`                                                                                                                                                                                          |

A flag is its **fallback** whenever the source has no value for the key, has one of another type, throws, or has not
started: so the first frame never waits for a flag.

## The starter

A route behind a flag, its menu entry, a layout that lists the menu, the source in `startup()` and the tests. The
`HomePage` at `/` is the scratch app's own.

```dart
// lib/flags.dart
import 'package:fespalier_flags/fespalier_flags.dart';

/// /labs and its menu entry: off unless startup.dart or a test turns it on.
const labs = BoolFlag('labs');
```

```dart
// lib/app/labs/page.dart
import 'package:flutter/material.dart';

class LabsPage extends StatelessWidget {
  const LabsPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('Labs');
}
```

```dart
// lib/app/labs/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/flags.dart';

/// /labs is there while the `labs` flag is on. The guard watches the flag, so turning it off takes the app off
/// /labs, and the menu, which asks this guard, hides the entry: nothing else knows about the flag.
GuardResult guard(Ref ref) => flagGuard(ref, labs, orElse: const HomeRoute().location);
```

```dart
// lib/app/labs/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

/// No `whenRefused`: a refused entry is hidden, which is what a flag wants.
const nav = Nav(label: 'Labs', icon: Icons.science_outlined, order: 6);
```

```dart
// lib/app/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

/// The menu, as text: an entry the guard refuses is not in it.
class AppLayout extends ConsumerWidget {
  const AppLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      Expanded(child: child),
      for (final item in AppMenu.watch(ref)) Text('menu: ${item.label(context)}'),
    ],
  );
}
```

```dart
// lib/app/startup.dart
import 'package:fespalier/startup.dart';
import 'package:fespalier_flags/fespalier_flags.dart';

/// `--dart-define=LABS=true` turns the flag on. A vendor's SDK goes here instead ([`flag-sources.md`](flag-sources.md)).
Future<List<Override>> startup() async => [
  flagSource.overrideWithValue(const ConstFlags({'labs': bool.fromEnvironment('LABS')})),
];
```

```dart
// test/labs_test.dart
import 'package:fespalier/testing.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:fespalier_flags/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void main() {
  testWidgets('/labs is there while the flag is on, and goes with it', (tester) async {
    final flags = FakeFlags({'labs': true});
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/labs'),
      overrides: [flagSource.overrideWithValue(flags)],
    );
    expect(currentLocation(tester), '/labs');
    expect(find.text('menu: Labs'), findsOneWidget);

    flags.set('labs', false); // delivered synchronously
    await tester.pump(); // one frame: the guard ran again, and the router moved
    expect(currentLocation(tester), '/');
    expect(find.text('menu: Labs'), findsNothing);
  });

  testWidgets('a cold deep link with the flag off is on / in the first frame', (tester) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/labs'),
      overrides: [flagSource.overrideWithValue(FakeFlags())],
      settle: false,
    );
    expect(currentLocation(tester), '/');
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('the menu entry shows and hides with the flag, with no navigation', (tester) async {
    final flags = FakeFlags();
    await pumpRouter(
      tester,
      AppRoutes.router(),
      overrides: [flagSource.overrideWithValue(flags)],
    );
    expect(find.text('menu: Labs'), findsNothing);
    flags.set('labs', true);
    await tester.pump();
    expect(find.text('menu: Labs'), findsOneWidget);
    expect(currentLocation(tester), '/');
  });

  testWidgets('without an override every flag is its fallback', (tester) async {
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/labs'));
    expect(currentLocation(tester), '/');
  });
}
```

## Patterns

- **A route behind a flag:** `lib/app/checkout-v2/guard.dart` is
  `flagGuard(ref, checkoutV2, orElse: const CartRoute().location)`; a `nav.dart` beside it is hidden while the flag is
  off. A whole section: the guard in `(labs)/guard.dart`.
- **The old URL goes to the new one while the flag is on:** `checkout/guard.dart` is
  `flagGuard(ref, checkoutV2, whenOff: true, orElse: const CheckoutV2Route().location)`.
- **The same URL, two pages:** no guard; the page switches:
  `ref.watch(flag(checkoutV2)) ? const CheckoutV2() : const CheckoutV1()`.
- **A flag and a sign-in:** one `guard.dart` per folder, so compose with `??`:
  `flagGuard(ref, labs, orElse: '/') ?? requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from))`
  (with [`fespalier_auth`](auth-package.md)), or `?? (ref.watch(session) ? null : '/login')`. Both return a `String?`
  synchronously, so the guard stays sync. Order matters: the first answer wins.
- **Disable instead of hide:** the folder's `nav.dart` sets `whenRefused: NavRefused.disable`.
- **A flow:** `flagGuard(ref, checkoutV2, orElse: '/', follow: false)` reads the flag once per navigation
  (`ref.read`). A checkout that is open stays open when the flag turns off, the next navigation applies the change, and
  a menu entry does not follow.
- **A value, not a switch:** `const pageSize = IntFlag('page_size', fallback: 20);` and `ref.watch(flag(pageSize))` in a
  provider or a widget; it runs again only when the number differs.

## Behaviour to rely on

- **Every read is synchronous, from memory.** A `FlagSource` answers without a network, file or platform-channel
  call; the vendor's SDK has loaded what it keeps on disk before `startup()` returns. A read that throws is the flag's
  fallback, and in debug prints
  `fespalier_flags: reading <key> threw, so its fallback (<fallback>) is used: <error>`. A guard never throws because of
  a flag, and a menu entry never stays pending because of one.
- **One subscription per `ProviderContainer`**, to `FlagSource.changes`: opened when the first flag is watched, cancelled
  when the last watched flag is disposed, and with the container. An event names keys (`FlagsChanged({'labs'})`) or all
  of them; **only the watched flags it names** are read again, and a guard, menu or widget runs again only when the value
  differs (Riverpod compares with `!=`). A source that never changes returns `null`, and there is nothing to
  subscribe to. Nothing polls.
- **A guard that redirected stays subscribed until the next navigation.** fespalier keeps a guard while the committed
  location runs it, and one that redirected is kept until the next commit, so a flag's subscription outlives the page it
  gated by one navigation: a cold deep link to `/labs` with the flag off is on `/`, and the flag is still listened to
  until the user goes elsewhere. It costs nothing, and `packages/fespalier_flags/test/guard_test.dart` pins it
  (`FakeFlags.listenerCount` is 1, then 0 after the next navigation), so a change in fespalier's guard lifetime is
  noticed.
- **A change while a page is open moves the app.** `follow: true` (the default) watches: turning the flag off on `/labs`
  takes the router to `orElse` in the next frame. Use `follow: false` where that is wrong.
- **`AsyncFlags`** reads `meanwhile` (`const ConstFlags()` by default: the fallbacks) until the future completes, then
  the new source, and sends one `FlagsChanged.all()`. It starts no timer: the future's callback is the whole of it. If
  the future fails, `meanwhile` stays and debug prints
  `fespalier_flags: AsyncFlags' source failed, so the values meanwhile stay: <error>`.
- **A source replaced at run time** (`ProviderContainer.updateOverrides`) is listened to afresh, and every watched flag
  is read again.
- **Initial values, with no timer.** `startup()` awaits only what is local (the vendor's disk cache) and returns the
  override; a vendor whose start waits for the network goes in `AsyncFlags`. An app that must see remote values before
  its first frame awaits the vendor in `startup()` with a `.timeout()` of its own: that timer is the app's choice.

## Traps

- **A vendor's async API in a guard.** PostHog's `isFeatureEnabled` is a `Future`: the guard answers a `Future`, the menu
  entry turns pending and the first frame is blank. Copy the value into a `FlagSource` and read that
  ([`flag-sources.md`](flag-sources.md): PostHog).
- **Two `guard.dart` files in one folder** is not a thing: compose with `??`.
- **A flag that is always off:** the app never overrode `flagSource` (every flag is its fallback), or the key is
  misspelled (use `FakeFlags.strict` in tests).
- **A guarded page under a pushed page** does not react until it is uncovered (the rule for every guard).
- **A cold deep link before the source is ready** sees the fallback. Await the vendor's local load in `startup()`.
- **A `route.dart` constant for a flag is not built** (it would be a second gating mechanism). Neither are vendor
  packages or a DevTools flag panel.

## Testing

`FakeFlags({'labs': true})` is a `FlagSource` of values in memory: `flagSource.overrideWithValue(fake)` in the
`overrides` of `pumpRouter`, or in `fsp test`'s `test/routes/setup.dart`:

```dart
// test/routes/setup.dart
// A flagged route is tested instead of skipped (a route with a guard and no `overrides` is skipped).
import 'package:fespalier/testing.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:fespalier_flags/testing.dart';

List<Override> overrides(String pattern) => [
  flagSource.overrideWithValue(FakeFlags({'labs': pattern == '/labs'})),
];
```

- **`set(key, value)`** changes a value and sends `FlagsChanged({key})` **synchronously**; `setAll({...})` sends one
  event; a `null` value removes the key. Call them from the test body, not while a widget builds; then `await
tester.pump()`.
- **`FakeFlags.strict({...})`** throws a `StateError` for a key it lacks
  (`Bad state: FakeFlags has no value for "labz"`) or a value of another type
  (`Bad state: FakeFlags has "labs" = yes (String), which is not a bool`), and reports it to `FlutterError.reportError`,
  so a typo fails a `testWidgets`; without the report the flag would read its fallback and the test would see a
  plausible wrong value.
- **`listenerCount`** is how many listen to its changes: 0 once nothing watches a flag (a `ProviderContainer` of your
  own disposes on a zero-duration timer: `await tester.pump(const Duration(milliseconds: 1))` first).
- Without an override every flag is its fallback, so a test written before the flag existed sees it off.

The messages are in [`fespalier-troubleshooting`](../../fespalier-troubleshooting/SKILL.md) (its
`diagnostics-flags-storage-network.md` page).
