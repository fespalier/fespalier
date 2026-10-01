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
/// when the test ends (since 0.5.0), so `LeakTesting` finds nothing left behind. Don't
/// dispose it yourself with an `addTearDown` registered before this call (those run after
/// this one's: a second `dispose` throws); disposing it in the test body is fine. A
/// disposed router is gone, so don't share one between tests.
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
}) async {
  assert(
    container == null || overrides.isEmpty,
    'pass overrides to your own ProviderContainer, or leave the container out',
  );
  final used =
      container ?? ProviderContainer(overrides: overrides, retry: retry);
  if (container == null) addTearDown(used.dispose);
  addTearDown(() => _dispose(router));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: used,
      child: MaterialApp.router(routerConfig: router),
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
  if (matches.isNotEmpty) {
    final top = matches.last;
    if (top is ImperativeRouteMatch) return top.matches.uri.toString();
  }
  return router.routeInformationProvider.value.uri.toString();
}
