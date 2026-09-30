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

/// Boots [router] in a `ProviderScope` and a `MaterialApp.router`, and returns
/// the `ProviderContainer` behind it (for `container.read(...)` in assertions).
///
/// [overrides] replace providers, e.g. a fake API. To share state with code that
/// runs outside the widget tree, pass your own [container] instead; it's yours to
/// dispose. [settle] (on by default) pumps until nothing is scheduled, which waits
/// out delays in fake `data.dart` code. Turn it off to look at a loading view, and
/// `pump` the time you want yourself.
///
/// The router comes from `AppRoutes.router(initialLocation: ...)`. Build one per test:
/// a router remembers where it navigated.
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
}) async {
  assert(
    container == null || overrides.isEmpty,
    'pass overrides to your own ProviderContainer, or leave the container out',
  );
  final used = container ?? ProviderContainer(overrides: overrides);
  if (container == null) addTearDown(used.dispose);
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
String currentLocation(WidgetTester tester) {
  final context = tester.element(find.byType(Navigator).first);
  return GoRouter.of(context).routeInformationProvider.value.uri.toString();
}
