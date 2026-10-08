# fespalier_flags

Feature flags for [fespalier](https://github.com/fespalier/fespalier) (since 0.9.0): a flag is a provider that answers
at once, a guard watches it (`flagGuard`), and a route behind a flag and its menu entry follow the flag, because menus
run guards. fespalier itself has no flag feature: no file kind, no `fespalier:` key, no `fsp` command, and the generated
code is the same bytes. This package depends on nothing beyond fespalier, starts no timer and polls nothing.

The docs cover all of it: [Feature flags](https://github.com/fespalier/fespalier/blob/main/docs/guards.md#feature-flags-fespalier_flags)
(the patterns, live updates, the caveats), [where values come from](https://github.com/fespalier/fespalier/blob/main/docs/guards.md#where-flag-values-come-from)
and [testing](https://github.com/fespalier/fespalier/blob/main/docs/guards.md#testing-flagged-routes). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.14.0
  fespalier_flags:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_flags
      ref: v0.14.0
```

<!-- x-release-please-end -->

## Wire it

Declare each flag once, gate the route in its `guard.dart`, and give the app a source in `startup()`:

```dart
// lib/flags.dart
const labs = BoolFlag('labs');

// lib/app/labs/guard.dart
GuardResult guard(Ref ref) => flagGuard(ref, labs, orElse: const HomeRoute().location);

// lib/app/startup.dart
Future<List<Override>> startup() async => [
  flagSource.overrideWithValue(const ConstFlags({'labs': bool.fromEnvironment('LABS')})),
];
```

`ref.watch(flag(labs))` reads a flag anywhere with a `Ref` or a `WidgetRef`. A source is a `FlagSource`: four
synchronous typed reads and an optional `Stream<FlagsChanged>`. `ConstFlags` is fixed values, `AsyncFlags` a source that
is not ready at start. Firebase Remote Config, LaunchDarkly, PostHog and GrowthBook are recipes (a class of 15 to 40
lines), not packages: see the fespalier-guards skill's `flag-sources.md`.

## Test it

```dart
final flags = FakeFlags({'labs': true});
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/labs'),
  overrides: [flagSource.overrideWithValue(flags)],
);
flags.set('labs', false); // delivered synchronously
await tester.pump(); // the guard ran again: the router is on orElse
```

`package:fespalier_flags/testing.dart` has `FakeFlags`; `FakeFlags.strict` fails on a key it lacks.

## Rules

- **Every read is synchronous and from memory.** A flag is never an `AsyncValue` or a `Future`; one that is not known
  yet is its fallback. Never call a vendor's async API in a guard.
- **No timer, no polling.** One subscription to `FlagSource.changes` per `ProviderContainer`, opened with the first
  watched flag and cancelled with the last.
- **A guard that redirected stays subscribed until the next navigation**, so a flag's subscription can outlive the page
  it gated by one navigation (fespalier's rule for guards; `test/guard_test.dart` pins it).
- Not built: a `route.dart` constant for a flag, vendor packages, a DevTools panel of flag values.
