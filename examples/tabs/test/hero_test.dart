// The profile avatar flies from the Profile tab to the settings page, which opens on the root
// navigator, over the tab bar (since 0.8.1). `RouteHero` stays out of flights in the tabs that
// are not shown, so the route above the tabs flies from the one that is.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';

final avatar = find.text('A');

Future<GoRouter> boot(WidgetTester tester, String location) async {
  final router = AppRoutes.router(initialLocation: location);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: mui.MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> midFlight(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('the avatar flies over the tab bar, and back', (tester) async {
    final router = await boot(tester, '/profile');
    expect(avatar, findsOneWidget);
    final from = tester.getCenter(avatar);

    router.push('/settings');
    await midFlight(tester);
    // In flight: one avatar, the shuttle, on its way.
    expect(avatar, findsOneWidget);
    final mid = tester.getCenter(avatar);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsNothing);
    expect(avatar, findsOneWidget);
    final to = tester.getCenter(avatar);
    expect(from, isNot(to));
    expect((mid - from).distance, greaterThan(1));
    expect((mid - to).distance, greaterThan(1));

    router.pop();
    await midFlight(tester);
    expect(avatar, findsOneWidget);
    expect(tester.getCenter(avatar), isNot(to));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.getCenter(avatar), from);
  });
}
