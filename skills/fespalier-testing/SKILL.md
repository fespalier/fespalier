---
name: fespalier-testing
description: "Testing an app built with fespalier — package:fespalier/testing.dart (pumpRouter and currentLocation), booting the generated router at any location, deep links, typed navigation, not-found views and unparsable segments, loading and error states, faking a backend with provider overrides, guards and sign-in, pure tests of locations, dataAt and match, and the traps that hang or fail a test (pending timers, retries, stale app.g.dart). Load before writing or changing a widget test that touches the router, or when a routing test hangs, leaves a timer pending, or reports the wrong location."
---

# fespalier-testing

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/vaam-apps/fespalier/blob/main/skills/README.md#versions).

`package:fespalier/testing.dart` has two helpers. It is a **separate library**, so
`package:fespalier/fespalier.dart` never imports `flutter_test`; the package lists
`flutter_test` (an SDK package) as a dependency, which your app already has as a dev
dependency.

```dart
import 'package:fespalier/testing.dart';

testWidgets('shows a product', (tester) async {
  final container = await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/products/2'),
    overrides: [apiProvider.overrideWithValue(FakeApi())],
  );
  expect(find.byType(ProductPage), findsOneWidget);
  expect(currentLocation(tester), '/products/2');

  // navigate with typed routes from any widget under the router
  ProductsRoute().go(tester.element(find.byType(ProductPage)));
  await tester.pumpAndSettle();
  expect(currentLocation(tester), '/products');
});
```

- **`pumpRouter(tester, router, {overrides, container, settle, retry})`** wraps the router
  in a `ProviderScope` and Flutter's `MaterialApp.router`, pumps, and returns the
  `ProviderContainer` (for `container.read(...)`).
  - `settle` (default **on**) pumps until nothing is scheduled; turn it off to look at a
    loading view, then `pump` the time you want.
  - Pass your own `container` **instead of** `overrides` to share one with code outside the
    tree (it is yours to dispose); passing both is an assertion.
  - **`retry` defaults to no retries**: a failing `data.dart` shows `error.dart` at once and
    leaves no timer. Pass `ProviderContainer.defaultRetry` (or your function) to test the
    app's policy.
- **`currentLocation(tester)`** is where the router is, as a string
  (`/products/2?tab=info`). It follows `go`, `pop` and, since 0.4.0, **`push`** (the
  pushed location, the top of the stack). On 0.3.0 and earlier it did not follow a
  `push`: there, read `router.routerDelegate.currentConfiguration.last.matchedLocation`.
- **One router per test**: a router remembers where it went. Build it in the test
  (`AppRoutes.router(initialLocation: ...)`), not in a shared `final`.
- **Boot once per test** when fakes use `Future.delayed`: a second boot leaves the first
  tree's timers behind (`A Timer is still pending even after the widget tree was
disposed`). A `for` loop that declares one `testWidgets` per location is the easy way.
- Import files from `$` folders with the dollar escaped:
  `import 'package:my_app/app/products/\$id/page.dart';`.

## What to test, and how

| You want to check                  | Do                                                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| A URL opens its page               | `pumpRouter(..., AppRoutes.router(initialLocation: '/products/2'))`, `find.byType(ProductPage)`                    |
| Not found                          | `/nope` or an unparsable segment (`/products/abc`): the page is never built, guards that read segments are skipped |
| Loading, then data                 | `settle: false`, `await tester.pump()`, `find.byType(ProductLoading)`, then `pump(delay)`                          |
| An error view                      | a fake that throws: `error.dart` shows at once (no retries in `pumpRouter`)                                        |
| A backend fake                     | override the provider your `data()` reads: `overrides: [apiProvider.overrideWithValue(FakeApi())]`                 |
| Typed navigation                   | `ProductRoute(id: 1).go(tester.element(find.byType(ProductsPage)))`, then `pumpAndSettle`                          |
| A guard                            | `c.read(session.notifier).signIn()` through the returned container, then navigate                                  |
| Locations, matches, data providers | plain `test()`: `.location`, `locationFor`, `AppRoutes.dataAt(uri)`, `AppRoutes.match(uri)`                        |
| A `WidgetRef` (prefetch, refresh)  | `tester.element(find.byType(SomeConsumerWidget)) as WidgetRef`                                                     |
| Restoration                        | your own app widget building the router in `State`, `restartAndRestore()`                                          |

Full compiled tests for all of these are in
[`references/recipes.md`](references/recipes.md); the traps, each of which cost a test
run while these skills were written, are in
[`references/pitfalls.md`](references/pitfalls.md).

## Three facts to keep in mind

1. go_router **builds the whole matched stack**: a deep link to `/products/2` also runs
   `/products`' `data.dart` underneath; pump long enough for both or `pumpAndSettle`.
2. **`fsp check` does not catch a stale `lib/app.g.dart`**: it writes and compares
   nothing. Regenerate and diff in CI (`dart run fespalier gen`, then
   `git diff --exit-code lib/app.g.dart`).
3. `await ProductRoute.read(ref, id: 1)` under a fake clock **hangs** until you `pump`
   the delay: start it, pump, then await.

Other skills: [`fespalier-data`](../fespalier-data/) for what the data providers do,
[`fespalier-guards`](../fespalier-guards/) for the guard behaviours you will be testing.
