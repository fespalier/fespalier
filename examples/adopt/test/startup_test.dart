// startup.dart's ready() and attach() (since 0.12.0), run by the generated main() around the
// half-moved router. AppMain.root() boots all of it as main() does; pumpRouter does not run them.
import 'package:adopt/app.main.g.dart';
import 'package:adopt/boot_log.dart';
import 'package:adopt/screens.dart';
import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    bootLog.clear();
    catalogLoads = 0;
  });

  testWidgets('ready() runs before the router is built, attach() after', (
    tester,
  ) async {
    await tester.pumpWidget(AppMain.root());
    await tester.pumpAndSettle();
    // zone() -> startup() -> the container -> ready() -> the router -> attach()
    expect(bootLog, ['ready', 'router', 'attach']);
    // app.dart's router() is the half-moved one: the first screen is the legacy home.
    expect(find.byType(LegacyHome), findsOneWidget);
  });

  testWidgets('the catalog ready() loaded is the one the routes use', (
    tester,
  ) async {
    await tester.pumpWidget(AppMain.root());
    await tester.pumpAndSettle();
    expect(catalogLoads, 1);

    await tester.tap(find.text('All products'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/shop');
    expect(find.text('Kettle'), findsOneWidget);

    await tester.tap(find.text('Kettle'));
    await tester.pumpAndSettle();
    expect(find.text('Kettle costs 39 €'), findsOneWidget);
    expect(catalogLoads, 1);
  });

  testWidgets('attach() has the router and the container', (tester) async {
    await tester.pumpWidget(AppMain.root());
    await tester.pumpAndSettle();
    // The app's own container: ProviderScope.containerOf finds it under UncontrolledProviderScope.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LegacyHome)),
    );
    // Something outside the widget tree asks for a product; attach() sent it to the typed route.
    container.read(openProductProvider.notifier).open(3);
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/shop/products/3');
    expect(find.text('Whisk costs 9 €'), findsOneWidget);
  });
}
