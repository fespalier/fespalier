import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:shop/app.main.g.dart';
import 'package:shop/app/products/loading.dart';
import 'package:shop/cart.dart';

/// Boots the generated router at [location], the same way main.dart does.
Future<ProviderContainer> boot(
  WidgetTester tester,
  String location, {
  FakeApi? api,
}) async {
  final container = ProviderContainer(
    overrides: [if (api != null) apiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  // /checkout and /products/:id are deferred routes (`const deferred = true;`): their code
  // loads on the real event loop, which a widget test's pumps never run, so load it first.
  // `pumpRouter` does this by itself; a test that pumps its own router does it like so.
  await tester.runAsync(AppRoutes.loadDeferred);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: AppRoutes.router(initialLocation: location),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('AppMain.root() is the app as main() runs it', (tester) async {
    // The generated main() loads the deferred code before runApp; a test does it likewise.
    await tester.runAsync(AppRoutes.loadDeferred);
    await tester.pumpWidget(AppMain.root());
    await tester.pumpAndSettle();
    expect(find.text('Browse products'), findsOneWidget);
    // app.dart: the title and the teal theme.
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Shop');
  });

  testWidgets('home renders inside the root layout', (tester) async {
    await boot(tester, '/');
    expect(find.text('Shop'), findsOneWidget);
    expect(find.text('Browse products'), findsOneWidget);
  });

  // A string path that matches a route works like the typed one; `fsp check` verifies
  // that it matches (and, with `unknown_path: error`, fails when it stops matching).
  testWidgets('a string path that matches a route navigates to it',
      (tester) async {
    await boot(tester, '/');
    await tester.tap(find.text('Most expensive first'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(currentLocation(tester), '/products?sort=expensive');
    // Sorted by price, the dearest first: the cheapest is on the second page.
    expect(find.text('Flaky grinder (fails once)'), findsOneWidget);
    expect(find.text('Coffee beans, 500 g'), findsNothing);
  });

  // `fsp:ignore unknown_path` in page.dart: the path matches no route, so it is not-found.
  testWidgets(
      'a silenced string path that matches no route shows not_found.dart',
      (tester) async {
    await boot(tester, '/');
    await tester.tap(find.text('Gift cards'));
    await tester.pump();
    expect(find.text('Nothing at /gift-cards'), findsOneWidget);
  });

  testWidgets('data.dart: loading.dart first, then the page', (tester) async {
    await boot(tester, '/products');
    expect(find.byType(ProductsLoading), findsOneWidget);
    expect(find.text('Ceramic mug'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ProductsLoading), findsNothing);
    expect(find.text('Ceramic mug'), findsOneWidget);
  });

  testWidgets('typed route navigation with int params', (tester) async {
    await boot(tester, '/products');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Pour-over kettle'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('€38.00'), findsOneWidget);
    expect(const ProductRoute(id: 3).location, '/products/3');
  });

  testWidgets('error.dart and retry', (tester) async {
    await boot(tester, '/products/13');
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining("Couldn't load product #13"), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Flaky grinder (fails once)'), findsOneWidget);
  });

  testWidgets('error.dart sees the typed error', (tester) async {
    await boot(tester, '/products/99');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Product #99 does not exist'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('unparsable params go to not_found.dart', (tester) async {
    await boot(tester, '/products/abc');
    await tester.pump();
    expect(find.text('Nothing at /products/abc'), findsOneWidget);
    // go_router still builds the /products page underneath; let it load.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('unknown paths go to not_found.dart', (tester) async {
    await boot(tester, '/nope');
    await tester.pump();
    expect(find.text('Nothing at /nope'), findsOneWidget);
  });

  testWidgets('guard.dart redirects an empty cart to /cart', (tester) async {
    await boot(tester, '/checkout');
    await tester.pump();
    expect(find.text('Your cart is empty'), findsOneWidget);
  });

  testWidgets('guard.dart lets a full cart through', (tester) async {
    final c = await boot(tester, '/');
    c.read(cartProvider.notifier).add(const Product(2, 'Ceramic mug', 12), 1);
    await tester.pump();
    final context = tester.element(find.text('Browse products'));
    const CheckoutRoute().go(context);
    await tester.pumpAndSettle();
    expect(find.text('Place order'), findsOneWidget);
  });

  testWidgets('an untyped segment is a String', (tester) async {
    await boot(tester, '/greet/you');
    await tester.pump();
    expect(find.text('Hello, you'), findsOneWidget);
    expect(const GreetRoute(name: 'a b').location, '/greet/a%20b');
  });

  testWidgets('refresh() re-runs data.dart', (tester) async {
    final api = CountingApi();
    await boot(tester, '/products', api: api);
    await tester.pump(const Duration(seconds: 1));
    expect(api.calls, 1);
    await tester.fling(find.text('Ceramic mug'), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(api.calls, 2);
  });

  testWidgets('mount(at:) embeds the tree under a prefix', (tester) async {
    addTearDown(() => AppRoutes.mount()); // restore base for other tests
    final router = GoRouter(
      initialLocation: '/shop/greet/mounted',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Text('legacy home')),
        ...AppRoutes.mount(at: '/shop'),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pump();
    expect(find.text('Hello, mounted'), findsOneWidget);
    expect(AppRoutes.base, '/shop');
    expect(const ProductRoute(id: 1).location, '/shop/products/1');
  });
}

class CountingApi extends FakeApi {
  var calls = 0;

  @override
  Future<List<Product>> products() {
    calls++;
    return super.products();
  }
}
