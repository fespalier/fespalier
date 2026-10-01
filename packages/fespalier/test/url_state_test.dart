// `routeOf` and `maybeRouteOf`, which the generated `XRoute.of(context)` calls: the location
// a widget belongs to, matched like `AppRoutes.matchUrl` matches one.

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class ProductRoute extends TypedLocation {
  const ProductRoute({required this.id, this.tab});
  final int id;
  final String? tab;
  @override
  String get location => '/products/$id';
}

final class ProductsRoute extends TypedLocation {
  const ProductsRoute({this.ref});
  final String? ref;
  @override
  String get location => '/products';
}

final class HelpRoute extends TypedLocation {
  const HelpRoute();
  @override
  String get location => '/help';
}

/// The matchers `fsp gen` writes, by hand. `base` is the mount point.
UrlMatch? match(Uri uri) => matchRoutes(uri, '/shop', [
  RouteMatcher(['products', ':id'], (s) {
    final route = ProductRoute(
      id: Segment.asInt(s, 'id'),
      tab: Query.asString(s, 'tab'),
    );
    return UrlMatch(s.uri, route, {'id': route.id, 'tab': route.tab}, []);
  }),
  RouteMatcher(['products'], (s) {
    final route = ProductsRoute(ref: Query.asString(s, 'ref'));
    return UrlMatch(s.uri, route, {'ref': route.ref}, []);
  }),
  RouteMatcher(['help'], (s) => UrlMatch(s.uri, const HelpRoute(), {}, [])),
], caseSensitive: false);

/// A router mounted at /shop whose products page has a nested product page, with a
/// layout around both, and a help page. Each page writes what it reads into [seen].
GoRouter router(String initial, Map<String, Object?> seen) => GoRouter(
  initialLocation: initial,
  routes: [
    ShellRoute(
      builder: (_, _, child) => Builder(
        builder: (context) {
          seen['layout'] = maybeRouteOf<TypedLocation>(context, match);
          return child;
        },
      ),
      routes: [
        GoRoute(
          path: '/shop/products',
          builder: (_, _) => Builder(
            builder: (context) {
              seen['products'] = maybeRouteOf<ProductsRoute>(context, match);
              seen['productsAsProduct'] = maybeRouteOf<ProductRoute>(
                context,
                match,
              );
              return const Text('products');
            },
          ),
          routes: [
            GoRoute(
              path: ':id',
              builder: (_, _) => Builder(
                builder: (context) {
                  seen['product'] = routeOf<ProductRoute>(context, match);
                  return const Text('product');
                },
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/shop/help',
          builder: (_, _) => Builder(
            builder: (context) {
              seen['help'] = maybeRouteOf<HelpRoute>(context, match);
              return const Text('help');
            },
          ),
        ),
      ],
    ),
  ],
);

Future<void> boot(WidgetTester tester, GoRouter router) =>
    tester.pumpWidget(MaterialApp.router(routerConfig: router));

void main() {
  testWidgets('a page reads its route, through the mount point and the query', (
    tester,
  ) async {
    final seen = <String, Object?>{};
    await boot(tester, router('/shop/products?ref=mail', seen));
    final route = seen['products']! as ProductsRoute;
    expect(route.ref, 'mail');
    // Another route's type is a null, not an error.
    expect(seen['productsAsProduct'], isNull);
  });

  testWidgets('the layout reads the whole location', (tester) async {
    final seen = <String, Object?>{};
    await boot(tester, router('/shop/products/7?tab=info', seen));
    expect(seen['layout'], isA<ProductRoute>());
    expect((seen['layout']! as ProductRoute).tab, 'info');
  });

  testWidgets('a page below another one reads its own route', (tester) async {
    final seen = <String, Object?>{};
    await boot(tester, router('/shop/products/7?ref=mail&tab=info', seen));
    // The nested page: its whole location.
    expect(seen['product'], isA<ProductRoute>());
    expect((seen['product']! as ProductRoute).id, 7);
    // The page under it is still the products page, with the location's query.
    final products = seen['products']! as ProductsRoute;
    expect(products.ref, 'mail');
  });

  testWidgets('it follows the location when it changes', (tester) async {
    final seen = <String, Object?>{};
    final r = router('/shop/products?ref=a', seen);
    await boot(tester, r);
    expect((seen['products']! as ProductsRoute).ref, 'a');
    r.go('/shop/products?ref=b');
    await tester.pump();
    expect((seen['products']! as ProductsRoute).ref, 'b');
  });

  testWidgets('the case setting of the matchers applies', (tester) async {
    final seen = <String, Object?>{};
    await boot(tester, router('/shop/products/7', seen));
    expect(seen['product'], isA<ProductRoute>());
  });

  testWidgets('routeOf throws a StateError naming the location', (
    tester,
  ) async {
    final seen = <String, Object?>{};
    await boot(tester, router('/shop/help', seen));
    final context = tester.element(find.text('help'));
    expect(
      () => routeOf<ProductRoute>(context, match),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('ProductRoute.of(context)'),
            contains('/shop/help'),
            contains('a HelpRoute'),
          ),
        ),
      ),
    );
    expect(maybeRouteOf<ProductRoute>(context, match), isNull);
  });

  testWidgets('a location no route matches is "no route"', (tester) async {
    final seen = <String, Object?>{};
    await boot(tester, router('/shop/help', seen));
    final context = tester.element(find.text('help'));
    expect(
      () => routeOf<HelpRoute>(context, (_) => null),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('no route'),
        ),
      ),
    );
  });

  testWidgets('outside any route: maybe is null, of is go_router\'s error', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final context = tester.element(find.byType(SizedBox));
    expect(maybeRouteOf<ProductRoute>(context, match), isNull);
    expect(
      () => routeOf<ProductRoute>(context, match),
      throwsA(isA<GoError>()),
    );
  });
}
