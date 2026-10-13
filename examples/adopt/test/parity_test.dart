// The same URLs open the same screens before and after the move. `lib/before/` is the app as it
// was (one hand-written GoRouter); `lib/router.dart` is the half-moved one. A row is an old URL,
// the screen it shows, a text on that screen, and where the half-moved app ends up (the URL a
// redirect forwards to, or the same URL when nothing moved).
//
// When a route moves, add a row for its old URL. When the whole tree has moved and lib/before/
// is deleted, this file goes with it.
import 'package:adopt/app.main.g.dart';
import 'package:adopt/before/main_before.dart';
import 'package:adopt/before/router_before.dart';
import 'package:adopt/router.dart';
import 'package:adopt/screens.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Row = ({String url, Type screen, String text, String after});

const rows = <Row>[
  // Never moved: the same code, the same URL.
  (url: '/', screen: LegacyHome, text: 'All products', after: '/'),
  (
    url: '/legacy/orders/7',
    screen: LegacyOrderView,
    text: 'Order 7',
    after: '/legacy/orders/7',
  ),
  // Moved: the old URL forwards to the typed route under /shop.
  (url: '/products', screen: ProductListView, text: 'Kettle', after: '/shop'),
  (
    url: '/products/2',
    screen: ProductDetailView,
    text: 'Kettle costs 39 €',
    after: '/shop/products/2',
  ),
  // A product that is not there: the same failure screen, with its Retry.
  (
    url: '/products/99',
    screen: LoadFailedView,
    text: 'Could not load the product',
    after: '/shop/products/99',
  ),
  // No product to go to: not found, at the URL that was asked for.
  (
    url: '/products/abc',
    screen: MissingView,
    text: 'Nothing at /products/abc',
    after: '/products/abc',
  ),
  (url: '/nope', screen: MissingView, text: 'Nothing at /nope', after: '/nope'),
];

Finder screen(Type type) =>
    find.byWidgetPredicate((w) => w.runtimeType == type);

void main() {
  for (final row in rows) {
    group('${row.url}:', () {
      testWidgets('before', (tester) async {
        await pumpRouter(tester, buildBeforeRouter(initialLocation: row.url));
        expect(screen(row.screen), findsOneWidget);
        expect(find.textContaining(row.text), findsWidgets);
        expect(currentLocation(tester), row.url);
      });

      testWidgets('after', (tester) async {
        await pumpRouter(
          tester,
          buildRouter(initialLocation: row.url),
          app: AppMain.app,
        );
        expect(screen(row.screen), findsOneWidget);
        expect(find.textContaining(row.text), findsWidgets);
        expect(currentLocation(tester), row.after);
      });
    });
  }

  testWidgets('the same taps lead to the same screens', (tester) async {
    // Home -> All products -> Kettle, in the old app and in the half-moved one.
    for (final after in [false, true]) {
      final router = after ? buildRouter() : buildBeforeRouter();
      await pumpRouter(tester, router, app: after ? AppMain.app : null);
      await tester.tap(find.text('All products'));
      await tester.pumpAndSettle();
      expect(screen(ProductListView), findsOneWidget);
      await tester.tap(find.text('Kettle'));
      await tester.pumpAndSettle();
      expect(screen(ProductDetailView), findsOneWidget);
      expect(find.text('Kettle costs 39 €'), findsOneWidget);
      expect(
        currentLocation(tester),
        after ? '/shop/products/2' : '/products/2',
      );
    }
  });

  testWidgets('the 0.11-style main still boots, with the catalog loaded', (
    tester,
  ) async {
    final root = (await tester.runAsync(beforeRoot))!;
    await tester.pumpWidget(root);
    await tester.pumpAndSettle();
    expect(screen(LegacyHome), findsOneWidget);
  });
}
