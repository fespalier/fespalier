// The product avatar flies from its row to the product's page (since 0.8.1): one
// `ProductRoute(id: ...).hero('avatar', child: ...)` on each side.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/app.g.dart';
import 'package:shop/app/layout.dart';
import 'package:shop/app/products/loading.dart';

/// The pour-over kettle's avatar is the only 'P' on the list.
final avatar = find.text('P');

Future<void> boot(WidgetTester tester) async {
  await pumpRouter(tester, AppRoutes.router(initialLocation: '/products'));
  // data.dart is slow on purpose (a timer, not a frame): wait it out.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('with the product preloaded, the avatar flies to its page', (
    tester,
  ) async {
    await boot(tester);
    // What hovering the row does (`RouteLink(preload: Preload.intent)`): the page is
    // then in the first frame of the transition, which is what a hero flies to.
    final handle = const ProductRoute(id: 3).preload(
      tester.element(find.byType(AppLayout)) as WidgetRef,
    );
    addTearDown(handle.close);
    await tester.pump(const Duration(seconds: 1));

    final from = tester.getCenter(avatar);
    await tester.tap(find.text('Pour-over kettle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // In flight: one avatar, the shuttle, on its way and not at either end.
    expect(avatar, findsOneWidget);
    final mid = tester.getCenter(avatar);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(currentLocation(tester), '/products/3');
    expect(avatar, findsOneWidget);
    final to = tester.getCenter(avatar);

    expect(from, isNot(to));
    expect((mid - from).distance, greaterThan(1));
    expect((mid - to).distance, greaterThan(1));
  });

  testWidgets('without the data, loading.dart shows and nothing flies', (
    tester,
  ) async {
    await boot(tester);
    final from = tester.getCenter(avatar);
    await tester.tap(find.text('Pour-over kettle'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The product's page is not there yet, so no hero is there to fly to: the row's
    // avatar is not a shuttle, it goes where its page goes (aside, to the left, as a
    // Material page does for the one over it), not toward the product's avatar.
    expect(find.byType(ProductsLoading), findsOneWidget);
    expect(avatar, findsOneWidget);
    expect(tester.getCenter(avatar).dx, lessThan(from.dx));
    expect(tester.takeException(), isNull);

    // The page arrives later: its avatar is just there, with no flight.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(ProductsLoading), findsNothing);
    expect(avatar, findsOneWidget);
  });
}
