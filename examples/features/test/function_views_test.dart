import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Future<void> boot(WidgetTester tester, String location) async {
  await tester.pumpWidget(
    ProviderScope(
      // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
      // nesting both gives Material pages and error screens on either.
      child: MaterialApp(
        home: mui.MaterialApp.router(
          routerConfig: AppRoutes.router(initialLocation: location),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// `page()` as a function: two routes, one widget, different constants.
void main() {
  testWidgets('the free route builds the screen with the free plan',
      (tester) async {
    await boot(tester, '/free');
    expect(find.text('Plan free'), findsOneWidget);
  });

  testWidgets('the pro route builds the same screen with the pro plan',
      (tester) async {
    await boot(tester, '/pro');
    expect(find.text('Plan pro'), findsOneWidget);
  });

  testWidgets('the function\'s parameters are bound like a constructor\'s',
      (tester) async {
    await boot(tester, '/pro?coupon=SPRING');
    expect(find.text('Plan pro (coupon SPRING)'), findsOneWidget);
  });

  test('the route class comes from the folder, or from routeName', () {
    // (plans) is a group: it adds nothing to the name or the URL.
    expect(const FreeRoute().location, '/free');
    expect(const ProPlanRoute().location, '/pro');
    expect(const ProPlanRoute(coupon: 'SPRING').location, '/pro?coupon=SPRING');
  });

  test('the manifest lists them under those names', () {
    expect(AppManifest.byType[FreeRoute]?.path, '/free');
    expect(AppManifest.byType[ProPlanRoute]?.path, '/pro');
  });
}
