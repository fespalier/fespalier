// The Routes tab: the tree as an outline, the current route highlighted, a filter, and details.
import 'package:fespalier_devtools/src/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';
import 'pump.dart';

Finder row(String route, String pattern) =>
    find.byKey(Key('route-$route-$pattern'));

void main() {
  testWidgets(
    'highlights the route the router is at, and opens the routes it nests in',
    (tester) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      final current = find.byKey(const Key('current-route'));
      expect(current, findsOneWidget);
      expect(
        find.descendant(of: current, matching: find.text('ReviewsRoute')),
        findsOneWidget,
      );
      // Its ancestors are open, so they show; a route the router is not under is closed.
      expect(find.text('CatalogRoute'), findsOneWidget);
      expect(find.text('ProductDetailRoute'), findsOneWidget);
      expect(find.text('NewDocRoute'), findsNothing);
    },
  );

  testWidgets('shows navigators as headers, with their markers', (
    tester,
  ) async {
    await pumpApp(tester, FakeFespalierClient());
    await openTab(tester, 'Routes');
    expect(find.text('layout layout.dart'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('layout reports/layout.dart'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('layout reports/layout.dart'), findsOneWidget);
  });

  testWidgets('shows each route\'s pattern, class, file and marker chips', (
    tester,
  ) async {
    await pumpApp(tester, FakeFespalierClient());
    await openTab(tester, 'Routes');
    await tester.enterText(
      find.byKey(const Key('routes-filter')),
      'RefundRoute',
    );
    await tester.pump();
    final refund = row('RefundRoute', '/orders/:id/refund');
    expect(refund, findsOneWidget);
    for (final text in [
      '/orders/:id/refund',
      'RefundRoute',
      'orders/\$id/refund/page.dart',
      'data',
      'action',
      'guard',
    ]) {
      expect(
        find.descendant(of: refund, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
  });

  group('filter', () {
    testWidgets('by route class leaves that branch', (tester) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      await tester.enterText(
        find.byKey(const Key('routes-filter')),
        'ProductRoute',
      );
      await tester.pump();
      // The features app has no ProductRoute; ProductDetailRoute does not contain it either.
      expect(find.text('No route matches the filter.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('routes-filter')),
        'productdetail',
      );
      await tester.pump();
      expect(row('ProductDetailRoute', '/catalog/:productId'), findsOneWidget);
      // Its parents stay, to show where it is; unrelated routes go.
      expect(row('CatalogRoute', '/catalog'), findsOneWidget);
      expect(find.text('LoginRoute'), findsNothing);
    });

    testWidgets('by pattern, or by file', (tester) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      await tester.enterText(find.byKey(const Key('routes-filter')), '/login');
      await tester.pump();
      expect(find.text('LoginRoute'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('routes-filter')),
        'old-search/redirect',
      );
      await tester.pump();
      expect(find.text('OldSearchRoute'), findsOneWidget);
      expect(find.text('redirect'), findsOneWidget);
    });

    testWidgets('is cleared by clearing the field', (tester) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      await tester.enterText(find.byKey(const Key('routes-filter')), 'login');
      await tester.pump();
      expect(find.text('CatalogRoute'), findsNothing);
      await tester.enterText(find.byKey(const Key('routes-filter')), '');
      await tester.pump();
      expect(find.text('CatalogRoute'), findsOneWidget);
    });
  });

  testWidgets('a chevron opens and closes the routes under a route', (
    tester,
  ) async {
    await pumpApp(
      tester,
      FakeFespalierClient(snapshot: fixture('snapshot_pushed')),
    );
    await openTab(tester, 'Routes');
    // Orders is not under the current route (the profile page is): it starts closed.
    final toggle = find.byKey(const Key('toggle-OrderRoute-/orders/:id'));
    await tester.scrollUntilVisible(
      toggle,
      400,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('RefundRoute'), findsNothing);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('RefundRoute'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('RefundRoute'), findsNothing);
  });

  group('details', () {
    Future<void> select(
      WidgetTester tester,
      String route,
      String pattern,
    ) async {
      await tester.enterText(find.byKey(const Key('routes-filter')), route);
      await tester.pump();
      await tester.tap(row(route, pattern));
      await tester.pump();
    }

    testWidgets('show the file, folder and parameters of a route', (
      tester,
    ) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      await select(tester, 'ProductDetailRoute', '/catalog/:productId');
      final details = find.byKey(const Key('route-details'));
      expect(details, findsOneWidget);
      for (final text in [
        'lib/app/catalog/\$productId/page.dart',
        'catalog/\$productId',
        'productId: String',
      ]) {
        expect(
          find.descendant(of: details, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
      // A route with a path parameter has no location to go to without a value.
      expect(find.byKey(const Key('route-go')), findsNothing);
    });

    testWidgets('list the other spellings of a localized route', (
      tester,
    ) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      await select(tester, 'HelpRoute', '/help');
      final details = find.byKey(const Key('route-details'));
      expect(
        find.descendant(of: details, matching: find.text('/aide')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('/hilfe')),
        findsOneWidget,
      );
    });

    testWidgets('list the guard, data and action sites on the route', (
      tester,
    ) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      await select(tester, 'RefundRoute', '/orders/:id/refund');
      final details = find.byKey(const Key('route-details'));
      expect(
        find.descendant(of: details, matching: find.text('guard')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('data')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: details, matching: find.text('action')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: details,
          matching: find.textContaining('orders/\$id/refund/guard.dart'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('say a data.dart that returns a provider is not followed', (
      tester,
    ) async {
      await pumpApp(tester, FakeFespalierClient());
      await openTab(tester, 'Routes');
      await select(tester, 'CatalogRoute', '/catalog');
      expect(
        find.textContaining('(returns or selects a provider)'),
        findsOneWidget,
      );
    });

    testWidgets('Go goes to a route that has no path parameter', (
      tester,
    ) async {
      final client = FakeFespalierClient();
      await pumpApp(tester, client);
      await openTab(tester, 'Routes');
      await select(tester, 'LoginRoute', '/login');
      await tester.tap(find.byKey(const Key('route-go')));
      await settle(tester);
      expect(client.callsTo(DevToolsMethods.navigate), [
        {'mode': 'go', 'location': '/login'},
      ]);
    });
  });

  testWidgets('says so when the app registered no routes', (tester) async {
    await pumpApp(
      tester,
      FakeFespalierClient(
        handlers: {
          DevToolsMethods.tree: (_) => {'protocol': 1, 'tree': null},
        },
      ),
    );
    await openTab(tester, 'Routes');
    expect(find.text('The app has not registered its routes.'), findsOneWidget);
  });
}
