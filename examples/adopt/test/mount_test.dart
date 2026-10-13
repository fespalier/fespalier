// The half-moved router: legacy routes, fespalier's tree under /shop, and the redirects between.
import 'package:adopt/app.g.dart';
import 'package:adopt/app.main.g.dart';
import 'package:adopt/app/page.dart';
import 'package:adopt/app/products/\$id/page.dart';
import 'package:adopt/router.dart';
import 'package:adopt/screens.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

// A new router for every test: a router remembers where it went.
Future<void> boot(WidgetTester tester, [String location = '/']) => pumpRouter(
  tester,
  buildRouter(initialLocation: location),
  app: AppMain.app,
);

void main() {
  testWidgets('a legacy route still works beside the mounted tree', (
    tester,
  ) async {
    await boot(tester, '/legacy/orders/7');
    expect(find.byType(LegacyOrderView), findsOneWidget);
    expect(find.text('Order 7'), findsOneWidget);
  });

  testWidgets('the mounted tree answers under /shop', (tester) async {
    await boot(tester, '/shop');
    expect(find.byType(ProductsPage), findsOneWidget);
    expect(find.text('Teapot'), findsOneWidget);

    await tester.tap(find.text('Whisk'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/shop/products/3');
    expect(find.byType(ProductPage), findsOneWidget);
    expect(find.text('Whisk costs 9 €'), findsOneWidget);
  });

  testWidgets('mount(at:) puts the prefix in every typed route', (
    tester,
  ) async {
    await boot(tester);
    expect(AppRoutes.base, '/shop');
    expect(const ProductsRoute().location, '/shop');
    expect(const ProductRoute(id: 2).location, '/shop/products/2');
  });

  testWidgets('a typed route works from a legacy page', (tester) async {
    await boot(tester);
    expect(find.byType(LegacyHome), findsOneWidget);
    ProductRoute(id: 3).go(tester.element(find.byType(LegacyHome)));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/shop/products/3');
    expect(find.byType(ProductPage), findsOneWidget);
  });

  testWidgets('legacy code that navigates by string is forwarded', (
    tester,
  ) async {
    await boot(tester);
    await tester.tap(find.text('Featured: Kettle'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/shop/products/2');
    expect(find.byType(ProductPage), findsOneWidget);
  });

  testWidgets('and the mounted pages go back to the host router by string', (
    tester,
  ) async {
    await boot(tester, '/shop');
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
    expect(find.byType(LegacyHome), findsOneWidget);
  });

  testWidgets('a segment that does not parse is not found, in the tree', (
    tester,
  ) async {
    await boot(tester, '/shop/products/abc');
    expect(find.byType(ProductPage), findsNothing);
    expect(find.text('Nothing at /shop/products/abc'), findsOneWidget);
  });

  testWidgets('a product that is missing shows error.dart', (tester) async {
    await boot(tester, '/shop/products/99');
    expect(find.text('Could not load the product'), findsOneWidget);
  });

  test('dataAt knows the mount point: a location outside it is null', () {
    // The mount stored `/shop`, whether or not a router is on screen.
    AppRoutes.mount(at: '/shop');
    expect(AppRoutes.dataAt(Uri.parse('/shop/products/2')), isNotNull);
    expect(AppRoutes.dataAt(Uri.parse('/legacy/orders/7')), isNull);
    expect(AppRoutes.dataAt(Uri.parse('/products/2')), isNull);
  });
}
