// Deferred routes: /checkout and /products/:id say `const deferred = true;` in their route.dart,
// so their page.dart is imported `deferred as` and is a chunk of its own on the web.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:shop/app/checkout/page.dart' deferred as checkout;
import 'package:shop/app/layout.dart';
import 'package:shop/cart.dart';

WidgetRef rootRef(WidgetTester tester) =>
    tester.element(find.byType(AppLayout)) as WidgetRef;

void main() {
  group('pumpRouter', () {
    testWidgets('loads the code first: a deep link shows the page', (
      tester,
    ) async {
      await pumpRouter(
          tester, AppRoutes.router(initialLocation: '/products/2'));
      // data.dart is slow on purpose (a timer, not a frame): wait it out.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Ceramic mug'), findsOneWidget);
      expect(find.text('Add to cart'), findsOneWidget);
      expect(AppRoutes.deferred, hasLength(2));
      expect(AppRoutes.deferred.every((l) => l.isLoaded), isTrue);
    });

    testWidgets('the guard still runs first, from eager code', (tester) async {
      await pumpRouter(tester, AppRoutes.router(initialLocation: '/checkout'));
      expect(find.text('Your cart is empty'), findsOneWidget);
      expect(find.text('Place order'), findsNothing);
    });

    testWidgets('with an item in the cart the checkout shows', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(cartProvider.notifier)
          .add(const Product(2, 'Ceramic mug', 12), 1);
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/checkout'),
        container: container,
      );
      expect(find.text('Place order'), findsOneWidget);
    });
  });

  testWidgets('a test that pumps its own router loads the code itself', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(cartProvider.notifier)
        .add(const Product(2, 'Ceramic mug', 12), 1);
    final router = AppRoutes.router(initialLocation: '/checkout');
    addTearDown(router.dispose);
    // Without this line the page can't load: `loadLibrary` only completes on the real event
    // loop, and fespalier says so (a FlutterError in debug builds) rather than hang.
    await tester.runAsync(AppRoutes.loadDeferred);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    expect(find.text('Place order'), findsOneWidget);
  });

  testWidgets('without it, a router of your own is told what to do', (
    tester,
  ) async {
    // A library of this test's own, so this is the first time anything asks for its code.
    final library = DeferredLibrary(checkout.loadLibrary, 'checkout/page.dart');
    await tester.pumpWidget(
      MaterialApp(
        home: DeferredView(
          library: library,
          page: () => checkout.CheckoutPage(),
          loading: () => const Text('loading'),
          error: (e, st, retry) => Text('$e'),
        ),
      ),
    );
    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    expect(
      (error! as FlutterError).diagnostics.first.toString(),
      "The code of checkout/page.dart is not loaded, and a widget test can't load it while it pumps.",
    );
  });

  test('the manifest says which routes are deferred', () {
    expect(AppManifest.byType[CheckoutRoute]!.deferred, isTrue);
    expect(AppManifest.byType[ProductRoute]!.deferred, isTrue);
    expect(AppManifest.byType[ProductsRoute]!.deferred, isFalse);
    expect(AppManifest.byType[HomeRoute]!.deferred, isFalse);
  });

  group('preload', () {
    testWidgets('a route loads its data, and its code stays loaded', (
      tester,
    ) async {
      final container = await pumpRouter(tester, AppRoutes.router());
      final handle = const ProductRoute(id: 2).preload(rootRef(tester));
      await tester.pump(const Duration(seconds: 1));
      expect(container.exists(ProductRoute.data(2)), isTrue);
      expect(AppRoutes.deferred.every((l) => l.isLoaded), isTrue);
      handle.close();
      await tester.pump();
      expect(container.exists(ProductRoute.data(2)), isFalse);
      // The data goes with the handle; the code, once loaded, stays.
      expect(AppRoutes.deferred.every((l) => l.isLoaded), isTrue);
    });

    testWidgets(
        'a deferred route that reads no data has a handle that holds nothing', (
      tester,
    ) async {
      await pumpRouter(tester, AppRoutes.router());
      final handle = const CheckoutRoute().preload(rootRef(tester));
      await tester.pump();
      expect(handle.isClosed, isTrue);
    });
  });
}
