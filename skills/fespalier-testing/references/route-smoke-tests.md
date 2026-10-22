# Route smoke tests: `fsp test`, `setup.dart` and `smokeTestRoute`

As of 0.8.1 (`cli/src/smoke.rs`, `cli/src/samples.rs`, `packages/fespalier/lib/testing.dart`). Everything here is
new in 0.8.1 except where it says otherwise (`test: a11y:` and `guidelines:` are 0.16.0): an app on an older fespalier
has no `fsp test`, no `smokeTestRoute` and no `pumpRouter(app:)`.

`fsp test` writes **one file**, `test/routes/routes_test.dart`, with a widget test per route. It proves what a
Maestro flow proves (the route exists, its guards let it through, its data loaded, its page was built) in
`flutter test`, with no device. It does not run Flutter. Commit the file, like `app.g.dart`, and keep it
current in CI:

```sh
fsp test --check   # exits 1 when the file is missing or stale
flutter test
```

## What a test does

`smokeTestRoute(tester, pattern, router, {page, overrides, app, timeout, guidelines})` runs (`guidelines`
since 0.16.0, see [Accessibility](#accessibility-test-a11y-since-0160)):

1. `pumpRouter(..., settle: false)`, which loads the code of deferred routes first.
2. It pumps **100 ms of fake time at a time** until the page is found. A `data.dart` fake that answers after
   a delay (the shop's `FakeApi` waits 700 ms) is waited out; nothing waits on the real clock.
3. It fails after `timeout` (30 s of fake time) with this message (a `fail`, so a `TestFailure`):

   ```text
   The page of /items is not on screen after 30000 ms of fake time: the router is at /sign-in. A guard that redirects, a data.dart that fails or never completes, or an exception while building (above) keeps it away.
   ```

4. `expect(page, findsOneWidget)`, then each of `guidelines` (none by default) with `meetsGuideline`.
5. It takes the tree down (`pumpWidget(SizedBox())`) and runs the clock `timeout` on. A fake's pending
   **one-shot** timer fires with no widget left to react, so the test does not end with "A Timer is still
   pending".

The page is `findRoutePage(pattern)` by default: a `Semantics` whose identifier is `route:<pattern>`, which
`semantics_ids: true` gives every page. It needs no semantics tree, and a page under another is off screen and
not found. Without `semantics_ids`, a class page is found with `find.byType(_i0.CartPage)` (the generated
file imports the page); a **function page has no type to find, so it is skipped**.

## Reading the failure

The location in the message is where the router ended:

| It says                                            | Likely cause                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `the router is at /sign-in` (not the route's path) | A guard redirected. Give `setup.dart` an `overrides` that signs the user in for that pattern                 |
| `the router is at` the route's own path            | The page never built: its `data.dart` failed (error view) or never completed, or building threw (read above) |
| Flutter's exception printed above the failure      | An exception while building. Fix it, or fake what it reads                                                   |

## `setup.dart`

Yours, never written by `fsp`; `test/routes/setup.dart` by default, or `test.setup`. `fsp test` only parses it
(tree-sitter) to see which of two top-level functions it declares, and imports it as `setup`:

```dart
// setup.dart, in test/routes/ (a fragment: apiProvider, FakeApi and cartProvider are your own)
import 'package:fespalier/testing.dart';

/// Called once per test, so every test gets a fresh fake.
List<Override> overrides(String pattern) => [
  apiProvider.overrideWithValue(FakeApi()),
  if (pattern == '/checkout') cartProvider.overrideWith(_FullCart.new),
];
```

- `List<Override> overrides(String pattern)`: the overrides that test boots with. It can vary by route (a signed-in
  user for a guarded route). Without it, **a guarded route is skipped**, because its guard would most likely
  redirect.
- `Widget app(GoRouter router)`: the app around the router, for an app that needs its theme, localizations or an
  inherited widget. The default is `MaterialApp.router(routerConfig: router)`.
- Each must take exactly one required positional parameter; a file with neither, or a function of another
  shape, is an error (`references/diagnostics-config-and-meta.md` in `fespalier-troubleshooting`).
- **A translated app needs both** (since 0.10.0, `fespalier_tolgee`): `overrides(pattern)` returns
  `fakeTranslations(bundled: ..., remote: FakeTranslations.strict())` and `app` returns the app that uses
  `TranslationScope.routerConfig`. Through the default app there is no scope, and the smoke test fails with
  `No TranslationScope found above this widget.` A `$lang` route also needs a sample, like any dynamic route
  ([`fespalier-i18n`](../../fespalier-i18n/references/testing.md)).
- A hand-written test boots the same way: `pumpRouter(tester, router, overrides: ..., app: setup.app)`.
- **`fsp create` writes one** with the `image` feature (since 0.21.0): `overrides` boots `/photo` over a fake CDN (`FakeImages` over a `FakeTransport` that sends nothing). A setup file makes `fsp test` run guarded routes, so `fsp create` then lists `/account` and `/sign-in` (`auth`) and `/labs` (`flags`) under `test: skip:`, each with the test that opens it; without the `image` feature there is no setup file and `fsp test` skips a guarded route itself.

## Skips and samples

A route gets no test, and `fsp test` prints `skipped <pattern>: <reason>` (indented by two spaces) on every run (and lists it in the
file's header), when it is a redirect, listed in `test.skip`, a dynamic route with no sample, guarded with no
`overrides`, or a function page without `semantics_ids`. None fails `--check`. A route with
`const linkable = false;` is tested. Samples are `test.samples`, else `maestro.samples` (only that key of
`maestro:` is read), else none; the format and the checks are Maestro's.

## Accessibility: `test: a11y:` (since 0.16.0)

`fespalier: test: a11y:` makes every smoke test also check Flutter's accessibility guidelines once its page is on
screen, with the semantics tree on. The default is off, and an app that never sets it gets the file it always got.

```yaml
fespalier:
  test:
    a11y: true # every guideline
    # a11y: [tap_targets, labels] # or some of them; false and [] are none
```

| Value         | Passes to `meetsGuideline`                                              | A failure says                                                                      |
| ------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `tap_targets` | `androidTapTargetGuideline` (48×48) and `iOSTapTargetGuideline` (44×44) | `expected tap target size of at least Size(48.0, 48.0), but found Size(88.0, 28.0)` |
| `labels`      | `labeledTapTargetGuideline`                                             | `Expected: Tappable widgets should have a semantic label`                           |
| `contrast`    | `textContrastGuideline`                                                 | `Expected contrast ratio of at least 4.5 but found 1.10 for a font size of 14.0.`   |

- **The generated test.** `true` (or a list of all three) adds `guidelines: routeA11yGuidelines,` to each
  `smokeTestRoute`, after `app:` and before `timeout:`. A list of only some declares
  `const _a11y = [androidTapTargetGuideline, ...];` once, before `void main()`, and passes `guidelines: _a11y,`. The
  header of the file gains `// Each test also checks Flutter's accessibility guidelines (tap targets, labels)` and
  `// once its page is on screen.` with the words of the guidelines that are on. The set is read in a fixed order and
  each once, so the same set is the same file.
- **`routeA11yGuidelines`** (`package:fespalier/testing.dart`) is the four Flutter constants. A hand-written test
  passes it, or any `List<AccessibilityGuideline>`, as `guidelines:`; empty is the default and changes nothing. The
  semantics handle is taken for the check and released after it, also when the test fails, so a test that runs with
  `semanticsEnabled: false` still checks.
- **The whole tree is checked,** the layout's app bar, tab bar and floating buttons included, so one inaccessible widget
  in shared chrome fails **every route** under it. Fix the widget once (`examples/shop` needed a `tooltip` on three
  `IconButton`s and a `TextButton` in place of an `InkWell` around a `Text`). The first guideline that fails ends a
  test, so the next kind of problem shows only after the first is fixed.
- **Contrast reads the rendered pixels** and runs on the real event loop inside the fake clock (Flutter does that
  itself), so it works, but it can move with a Flutter upgrade; `tap_targets` and `labels` read the semantics tree. An
  app with a known contrast problem lists the other two, with a comment saying why.
- **Messages** (`fsp test` only; `gen` never reads them): `` `fespalier.test.a11y` is `true` (every guideline), `false`, or a list of `tap_targets`, `labels` and `contrast`, got `sometimes` `` and
  `` `fespalier.test.a11y`: `colour` is not a guideline; use `tap_targets` (48×48 on Android, 44×44 on iOS), `labels` or `contrast` ``
  (`references/diagnostics-config-and-meta.md` in `fespalier-troubleshooting`). The unknown-key list under `test:`
  ends with `a11y` since 0.16.0.

## Pitfalls

- **A periodic timer in a fake still fails the test.** Draining runs one-shot timers (and a `keepFor`) only. A
  `Timer.periodic` in a fake, or a stream that never closes under a `ref.listen`, leaves "A Timer is still
  pending": cancel it in `ref.onDispose`.
- **A fake must not need the real network.** The fake clock never advances a real socket; a `data.dart` that
  reaches one waits out `timeout` and fails with the message above.
- **Never edit `routes_test.dart`.** It is rewritten by `fsp test`, and `--check` fails on an edit. Put what
  differs in `setup.dart`, in `test.skip`, or in a test file of your own.
- **A file there that `fsp test` did not write** is never overwritten: it is an error naming the file. Move
  yours, or set `test.out`.
- **`dart format`.** The file starts with `// dart format off` and is laid out one argument to a line with
  trailing commas, which `dart format` leaves alone in both styles (before Dart 3.7 it does not read the
  marker). Do not reformat it by hand.
- **Query parameters and localized spellings are not tested**: each route opens at its canonical path.

Other pages: [`recipes.md`](recipes.md) for hand-written tests, [`pitfalls.md`](pitfalls.md) for the traps that
hang a test, [`maestro.md`](maestro.md) for a device or the web.
