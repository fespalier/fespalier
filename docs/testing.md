# Testing

## pumpRouter and currentLocation

```dart
import 'package:fespalier/testing.dart';

testWidgets('shows a product', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/products/2'),
    overrides: [apiProvider.overrideWithValue(FakeApi())],
  );
  expect(find.byType(ProductPage), findsOneWidget);

  // navigate with the typed routes, from any widget under the router
  ProductsRoute().go(tester.element(find.byType(ProductPage)));
  await tester.pumpAndSettle();
  expect(currentLocation(tester), '/products');
});
```

`package:fespalier/testing.dart` has two helpers for widget tests, plus `RecordingTelemetry` (see [Testing
telemetry](observability.md#testing-telemetry)):

- `pumpRouter` boots the app at a location.
- `currentLocation` reads where it is. It follows `go`, `pop` and `push`: after a push it is the pushed location, the top of the stack.

`observe.dart` hooks run after the frame, so `await tester.pump()` before looking at what they did.

`pumpRouter(tester, router, {overrides, container, settle, retry, disposeRouter, app})` wraps the router in a
`ProviderScope` and Flutter's `MaterialApp.router` (or the widget `app` builds, see below), and returns the `ProviderContainer`
(for `container.read(...)`).

- **`settle`** (on by default) pumps until nothing is scheduled. Turn it off to look at a loading view, then `pump` the time you want.
- **`container`**: pass your own instead of `overrides` to share one with code outside the widget tree. It's yours to dispose.
- **`retry`** is the container's Riverpod retry policy. It defaults to **no retries**, unlike a real app, whose generated providers keep Riverpod's automatic retry unless `data_retry: none` says otherwise. So a failing `data.dart` shows its `error.dart` at once and leaves no timer behind. To test what the app's policy does, pass `retry: ProviderContainer.defaultRetry` (or your own function). A policy that keeps retrying leaves a timer pending when the test ends, so dispose the returned container first.
- **`disposeRouter`**: `pumpRouter` disposes the router when the test ends (since 0.5.0), so `LeakTesting` finds nothing left behind. A test that disposes it itself with an `addTearDown` registered before the call (as tests written for 0.4.x do) passes `disposeRouter: false` (since 0.6.0): those teardowns run after `pumpRouter`'s, and a second `dispose` throws.

Tips:

- Make a new router per test, since a router remembers where it went. Don't share one between tests.
- The generated `AppRoutes` remembers the last `router()` or `mount()` (its `base` and `rootNavigatorKey`), and a call without a `navigatorKey` makes a fresh one (since 0.5.0). A test that mounts under a prefix restores the defaults with `addTearDown(AppRoutes.mount)`, so no test depends on the order they run in.
- Return synchronously from a guard when you can (see [Guards](guards.md)): any `Future`, even `Future.value(...)`, costs a frame, so a test sees a blank first frame before the page, where a synchronous guard shows the page at once.
- If a widget hangs on to its own `WidgetRef` (to call `prefetch` from a test, say), take it from an element: `tester.element(find.byType(AppLayout)) as WidgetRef`.
- A link the platform opens while the app runs is `await sendPlatformLink(tester, Uri.parse('https://shop.example.com/products/2'))` (since 0.12.0, from `package:fespalier/testing.dart`); see [Platform links end to end](navigation.md#platform-links-end-to-end).
- go_router builds the whole matched stack, so a deep link like `/products/2` also runs `/products`' `data.dart` underneath. If your fakes use `Future.delayed`, pump long enough for the delays in both (or use `pumpAndSettle`), or the test ends with "A Timer is still pending".

The library is separate from `package:fespalier/fespalier.dart`, so your app never imports
`flutter_test`. It's a regular `flutter_test: sdk: flutter` dependency of `fespalier`
(pub allows the Flutter SDK's own packages), which your app has as a dev dependency
anyway and doesn't ship. The helper uses Flutter's `MaterialApp`; with go_router 18 the
note under [Getting started](getting-started.md#go_router-18-and-material) applies: with a root `transition.dart`,
which `fsp init` writes, routes animate and no nested `material_ui` app is needed in tests.

`examples/*/test/` has working tests for every file kind. For tests on a device or in a browser, and
journeys across routes, see [Maestro flows](route-tests.md#maestro-flows-fsp-maestro).

## The app around the router

Since 0.8.1. `app:` is a `Widget Function(GoRouter router)` that builds
what goes around the router in place of the plain `MaterialApp.router`. With the
[generated `main()`](app-startup.md), `app: AppMain.app` boots a page in
`lib/app/app.dart`'s theme, localizations and `builder:`, as it runs. `startup()` does not run in
`pumpRouter`: pass what it would override as `overrides`. To boot everything, startup and splash
included, pump `AppMain.root()`:

```dart
testWidgets('starts, then shows the home page', (tester) async {
  await pumpRouter(tester, AppRoutes.router(initialLocation: '/about'), app: AppMain.app);

  // or the whole boot: splash.dart while startup() runs, then the app
  await tester.pumpWidget(AppMain.root(router: () => AppRoutes.router(initialLocation: '/about')));
  await tester.pumpAndSettle(); // a startup() that awaits a fake settles here; real I/O needs tester.runAsync
});
```

A `startup()` that throws is reported to `FlutterError.onError`, which a widget test fails on:
call `tester.takeException()` before you look at the splash. A test that runs `AppMain.run()`
itself (to check a `zone()`) pumps afterwards; `examples/features/test/startup_test.dart` does
all of these.

`pumpRouter` also takes `app:` (since 0.8.1), a function from the router to the app widget around it
(the default is `MaterialApp.router(routerConfig: router)`), and `package:fespalier/testing.dart` exports
riverpod's `Override`. `findRoutePage(pattern)` finds a page by its `semantics_ids` identifier, and
`smokeTestRoute` is what [`fsp test`](route-tests.md#route-smoke-tests-fsp-test) runs for each route; the shop's generated
smoke tests are checked by `just check-examples`.

## Deferred routes in tests

`pumpRouter` loads the code of every [deferred route](navigation.md#deferred-routes-a-pages-code-on-demand) first, on the real event loop
(since 0.7.0): a widget test's `pump` never runs `loadLibrary()`, so without that a deferred page would
show `loading.dart` for ever. A test that pumps a router of its own calls
`await tester.runAsync(AppRoutes.loadDeferred);` before `pumpWidget`; forgetting it is a `FlutterError` in
a debug build ("The code of products/$id/page.dart is not loaded, and a widget test can't load it while it
pumps."), not a hang.

## Importing from a $segment folder

To import a file from a `$segment` folder, escape the `$`: an unescaped `$id` in an import
is a Dart interpolation error ("URIs can't use string interpolation").

```dart
import 'package:my_app/app/products/\$id/page.dart';
```

## Testing each package

Each package and command has its own testing notes:

- Feature flags: [Testing flagged routes](guards.md#testing-flagged-routes) (`FakeFlags`).
- Signed-in routes: [Testing signed-in routes](auth.md#testing-signed-in-routes) (`fakeAuth`).
- Telemetry: [Testing telemetry](observability.md#testing-telemetry) (`RecordingTelemetry`).
- Sentry: [Testing with Sentry](observability.md#testing-with-sentry) (`RecordingSentry`).
- Images: [Testing images](responsive-images.md#testing-images) (`FakeImages`).
- A smoke test per route: [Route smoke tests](route-tests.md#route-smoke-tests-fsp-test).
- On a device or in a browser: [Maestro flows](route-tests.md#maestro-flows-fsp-maestro).
