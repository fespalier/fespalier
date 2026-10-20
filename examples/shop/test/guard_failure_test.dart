// A guard that fails (since 0.21.0): the checkout's guard reads a cart that cannot be read. The
// router's error route shows the route's error.dart (RootError, with a retry), the failure is
// reported once, and the retry runs the guard again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fespalier/fespalier.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';

import 'images.dart';

/// A cart whose state cannot be built, as a broken store would leave it.
class BrokenCart extends Cart {
  @override
  Map<int, CartLine> build() => throw StateError('the cart is unavailable');
}

/// Boots the generated router at [location] the way app_test.dart's `boot` does, and gives it back.
Future<GoRouter> boot(WidgetTester tester, String location) async {
  final container = ProviderContainer(
    overrides: [cartProvider.overrideWith(BrokenCart.new), fakeImages()],
  );
  addTearDown(container.dispose);
  // /checkout is a deferred route: its code loads on the real event loop.
  await tester.runAsync(AppRoutes.loadDeferred);
  final router = AppRoutes.router(initialLocation: location);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  return router;
}

void main() {
  testWidgets(
      'a checkout whose guard fails shows the error view, and a retry '
      'runs the guard again', (tester) async {
    final router = await boot(tester, '/checkout');
    await tester.pumpAndSettle();

    // The failure is reported once, in every build mode: the test takes it.
    expect(tester.takeException(), isA<StateError>());
    final error = router.routerDelegate.currentConfiguration.error;
    expect(error, isA<GuardFailure>());
    expect(router.routerDelegate.currentConfiguration.uri.path, '/checkout');
    // The person sees a message of the app's, not the exception.
    expect(find.text('Something went wrong.'), findsOneWidget);
    expect(find.textContaining('the cart is unavailable'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    // The retry ran the guard, which failed again, with a new report.
    expect(tester.takeException(), isA<StateError>());
    expect(find.text('Something went wrong.'), findsOneWidget);
  });
}
