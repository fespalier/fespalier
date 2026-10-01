import 'package:features/app.g.dart';
import 'package:features/app/orders/\$id/page.dart';
import 'package:features/app/orders/\$id/refund/confirm/page.dart';
import 'package:features/app/orders/\$id/refund/data.dart' as refund_data;
import 'package:features/app/orders/\$id/refund/page.dart';
import 'package:features/app/orders/\$id/refund/receipt/page.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

/// `orders/$id/refund/confirm/route.dart` says `const nest = false;`: the route is the
/// sibling `refund/confirm` of the `refund` page, not a child of it. `refund/receipt/` has no
/// such file, and nests.
void main() {
  late GoRouter router;

  Future<void> boot(WidgetTester tester, String location) async {
    router = AppRoutes.router(initialLocation: location);
    await tester.pumpWidget(
      ProviderScope(
        // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
        // nesting both gives Material pages and error screens on either.
        child: MaterialApp(
          home: mui.MaterialApp.router(
            routerConfig: router,
            // The pages have an AppBar, which reads flutter's MaterialLocalizations.
            localizationsDelegates: const [
              DefaultMaterialLocalizations.delegate,
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String location() =>
      router.routerDelegate.currentConfiguration.last.matchedLocation;

  setUp(refund_data.quoted.clear);

  /// Every page of the navigator's stack, the covered ones too.
  bool built<T extends Widget>() =>
      find.byType(T, skipOffstage: false).evaluate().isNotEmpty;

  group('a sibling with a compound path', () {
    testWidgets(
      'a deep link builds the order and the page, not the refund page between',
      (tester) async {
        await boot(tester, '/orders/1/refund/confirm');
        expect(find.text('Confirm refund of order 1'), findsOneWidget);
        expect(location(), '/orders/1/refund/confirm');

        // The stack is /orders/1, /orders/1/refund/confirm.
        expect(built<OrderPage>(), isTrue);
        expect(built<ConfirmRefundPage>(), isTrue);
        expect(built<RefundPage>(), isFalse);
        expect(
            find.byType(DataView<String>, skipOffstage: false), findsNothing);
        // Nothing was read for the page that shares its first segment.
        expect(refund_data.quoted, isEmpty);

        // Back goes to the order, as it does for GoRoute(path: 'refund/confirm')
        // written beside GoRoute(path: 'refund').
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(location(), '/orders/1');
        expect(find.text('Order 1'), findsOneWidget);
        expect(built<ConfirmRefundPage>(), isFalse);
      },
    );

    testWidgets('going from the refund page replaces it, back is the order', (
      tester,
    ) async {
      await boot(tester, '/orders/1/refund');
      expect(find.text('Up to 10 EUR back'), findsOneWidget);
      expect(refund_data.quoted, [1]);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(location(), '/orders/1/refund/confirm');
      expect(find.text('Confirm refund of order 1'), findsOneWidget);
      // The URL is below /orders/1/refund; the page is not.
      expect(built<RefundPage>(), isFalse);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(location(), '/orders/1');
    });

    testWidgets('a folder without the declaration still nests', (tester) async {
      await boot(tester, '/orders/1/refund/receipt');
      expect(find.text('Receipt for order 1'), findsOneWidget);
      // /orders/1, /orders/1/refund, /orders/1/refund/receipt
      expect(built<OrderPage>(), isTrue);
      expect(built<ReceiptPage>(), isTrue);
      // The refund page is under the receipt: its data was read, and it shows once the
      // receipt is popped (Riverpod pauses what a covered page watches, so it is still
      // loading until then).
      expect(
          find.byType(DataView<String>, skipOffstage: false), findsOneWidget);
      expect(refund_data.quoted, [1]);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(location(), '/orders/1/refund');
      expect(find.text('Up to 10 EUR back'), findsOneWidget);
    });

    testWidgets('the guard of the refund folder still guards the route', (
      tester,
    ) async {
      // Order 0 was refunded: refund/guard.dart sends every route in the folder back.
      await boot(tester, '/orders/0/refund/confirm');
      expect(location(), '/orders/0');
      expect(find.text('Confirm refund of order 0'), findsNothing);
      expect(refund_data.quoted, isEmpty);

      await boot(tester, '/orders/0/refund');
      expect(location(), '/orders/0');
    });

    testWidgets('typed routes, locations and the manifest are the same', (
      tester,
    ) async {
      const route = ConfirmRefundRoute(id: 7);
      expect(route.location, '/orders/7/refund/confirm');

      final info = AppManifest.byType[ConfirmRefundRoute]!;
      expect(info.path, '/orders/:id/refund/confirm');
      expect(info.folder, r'orders/$id/refund/confirm');
      expect(info.segments.map((s) => (s.name, s.type)), [('id', 'int')]);

      final m = AppRoutes.match(Uri.parse('/orders/7/refund/confirm'))!;
      expect(m.info.path, '/orders/:id/refund/confirm');
      expect(
        m.route,
        isA<ConfirmRefundRoute>().having((r) => r.id, 'id', 7),
      );

      // Navigating by the typed route builds the same stack as the deep link.
      await boot(tester, '/');
      route.go(tester.element(find.byType(Scaffold).first));
      await tester.pumpAndSettle();
      expect(location(), '/orders/7/refund/confirm');
      expect(built<RefundPage>(), isFalse);
      expect(built<OrderPage>(), isTrue);
    });
  });
}
