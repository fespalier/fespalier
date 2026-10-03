/// Helpers for widget tests of an app built with fespalier.
///
/// A separate library, so `package:fespalier/fespalier.dart` never imports
/// `flutter_test`:
///
/// ```dart
/// import 'package:fespalier/testing.dart';
///
/// testWidgets('opens a product', (tester) async {
///   await pumpRouter(tester, AppRoutes.router(initialLocation: '/products/2'));
///   expect(find.byType(ProductPage), findsOneWidget);
///   expect(currentLocation(tester), '/products/2');
/// });
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;

import 'src/deferred.dart';

/// Riverpod's `Override`, the type of the list `overrides` and `pumpRouter(overrides:)` take
/// (since 0.8.0): the setup file of `fsp test` returns a `List<Override>` and imports it from
/// here.
export 'package:hooks_riverpod/misc.dart' show Override;

Duration? _noRetry(int retryCount, Object error) => null;

/// Disposes [router] unless the test already did: a second `dispose` is an error.
void _dispose(GoRouter router) {
  try {
    router.dispose();
  } on FlutterError {
    // Disposed by the test itself.
  }
}

/// Boots [router] in a `ProviderScope` and a `MaterialApp.router`, and returns
/// the `ProviderContainer` behind it (for `container.read(...)` in assertions).
///
/// [overrides] replace providers, e.g. a fake API. To share state with code that
/// runs outside the widget tree, pass your own [container] instead; it's yours to
/// dispose. [settle] (on by default) pumps until nothing is scheduled, which waits
/// out delays in fake `data.dart` code. Turn it off to look at a loading view, and
/// `pump` the time you want yourself.
///
/// The container has no retries, so a failing `data.dart` shows its `error.dart`
/// at once and leaves no timer behind; pass [retry] (for example
/// `ProviderContainer.defaultRetry`) to test what the app's own policy does.
///
/// The router comes from `AppRoutes.router(initialLocation: ...)`. Build one per test:
/// a router remembers where it navigated. The test owns it, but `pumpRouter` disposes it
/// when the test ends (since 0.5.0), so `LeakTesting` finds nothing left behind. Disposing
/// it in the test body is fine. To keep disposing it yourself, as tests written for 0.4.x do
/// with an `addTearDown(router.dispose)` registered before this call (those run after this
/// one's, and a second `dispose` throws), pass `disposeRouter: false` (since 0.6.0). A
/// disposed router is gone, so don't share one between tests.
///
/// The code of every deferred route (`const deferred = true;`) is loaded first, on the real
/// event loop (since 0.7.0): a widget test's pumps never run it, so a deferred page behaves
/// as an eager one, and is in the first settled frame. A test that pumps a router of its
/// own calls `await tester.runAsync(AppRoutes.loadDeferred)` before it. An app without
/// deferred routes is booted exactly as before.
///
/// [app] builds the app around the router (since 0.8.0); the default is
/// `MaterialApp.router(routerConfig: router)`. Give it for an app that needs its theme,
/// localizations or an inherited widget of its own.
///
/// This app is Flutter's `MaterialApp`. With go_router 18, which looks for
/// `package:material_ui`'s instead, routes without a `transition.dart` don't
/// animate in tests, and go_router's own error screen is unstyled (see the README).
Future<ProviderContainer> pumpRouter(
  WidgetTester tester,
  GoRouter router, {
  List<Override> overrides = const [],
  ProviderContainer? container,
  bool settle = true,
  Duration? Function(int retryCount, Object error)? retry = _noRetry,
  bool disposeRouter = true,
  Widget Function(GoRouter router)? app,
}) async {
  assert(
    container == null || overrides.isEmpty,
    'pass overrides to your own ProviderContainer, or leave the container out',
  );
  final used =
      container ?? ProviderContainer(overrides: overrides, retry: retry);
  if (container == null) addTearDown(used.dispose);
  if (disposeRouter) addTearDown(() => _dispose(router));
  // A deferred route's code: `loadLibrary` only completes on the real event loop, which a
  // widget test's pumps don't run.
  if (DeferredLibrary.anyPending) {
    await tester.runAsync(DeferredLibrary.loadAll);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: used,
      child: app?.call(router) ?? MaterialApp.router(routerConfig: router),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return used;
}

/// Where the router is now, as a string (`/products/2?tab=info`), for a router
/// booted with [pumpRouter] or `MaterialApp.router`.
///
/// It follows `go`, `pop` and `push`: what a `push` shows is the top of the
/// stack, so that is its location. (go_router keeps the pushed page out of the
/// route information, which keeps showing the page underneath, so this reads the
/// router's current configuration instead.)
String currentLocation(WidgetTester tester) {
  final context = tester.element(find.byType(Navigator).first);
  final router = GoRouter.of(context);
  final matches = router.routerDelegate.currentConfiguration;
  // `lastOrNull` is the leaf: a page pushed inside a shell is in the shell's matches.
  final top = matches.lastOrNull;
  if (top is ImperativeRouteMatch) return top.matches.uri.toString();
  return router.routeInformationProvider.value.uri.toString();
}

/// The page of the route whose pattern is [pattern] (`/products/:id`), found by the
/// `Semantics(identifier: 'route:<pattern>')` that `semantics_ids: true` gives it. Needs no
/// semantics tree; a page off screen (underneath another) is skipped (since 0.8.0).
Finder findRoutePage(String pattern) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.identifier == 'route:$pattern',
  description: 'the page of $pattern',
);

/// What `fsp test` runs for each route (since 0.8.0): boots [router] with [pumpRouter] (and
/// [overrides], [app]), pumps on the fake clock until [page] (by default
/// `findRoutePage(pattern)`) is on screen, expects exactly one, then takes the tree down and
/// runs the clock [timeout] on so a fake's pending delay doesn't fail the test.
///
/// The wait is deterministic: it pumps 100 ms of fake time at a time, so a `data.dart` fake that
/// answers after a delay is waited out, and a page that never comes fails after [timeout] of
/// fake time, not real time, naming where the router is. A guard that redirects (no override to
/// get past it), a `data.dart` that fails or never completes, or an exception while building the
/// page keeps it away.
Future<void> smokeTestRoute(
  WidgetTester tester,
  String pattern,
  GoRouter router, {
  Finder? page,
  List<Override> overrides = const [],
  Widget Function(GoRouter router)? app,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final finder = page ?? findRoutePage(pattern);
  await pumpRouter(
    tester,
    router,
    overrides: overrides,
    app: app,
    settle: false,
  );
  const step = Duration(milliseconds: 100);
  var waited = Duration.zero;
  while (finder.evaluate().isEmpty) {
    if (waited >= timeout) {
      String at;
      try {
        at = currentLocation(tester);
      } on Object {
        at = 'unknown';
      }
      fail(
        'The page of $pattern is not on screen after ${timeout.inMilliseconds} ms of fake '
        'time: the router is at $at. A guard that redirects, a data.dart that fails or '
        'never completes, or an exception while building (above) keeps it away.',
      );
    }
    await tester.pump(step);
    waited += step;
  }
  expect(finder, findsOneWidget);
  // Take the tree down and run the clock on: a fake's pending one-shot timer fires with no
  // widget left to react, so the test does not end with "A Timer is still pending".
  await tester.pumpWidget(const SizedBox());
  await tester.pump(timeout);
}
