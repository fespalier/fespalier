import 'package:fespalier/fespalier.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';

/// The tab layout's own page is built by the nearest transition.dart (here the
/// root's, `Transitions.cupertino`), under a key that doesn't change.
late GoRouter router;

Future<void> boot(WidgetTester tester, String location) async {
  router = AppRoutes.router(initialLocation: location);
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
}

ModalRoute<Object?> shellRoute(WidgetTester tester) =>
    ModalRoute.of(tester.element(find.byType(NavigationBar)))!;

void main() {
  testWidgets('the shell is a page from transition.dart, with a stable key',
      (tester) async {
    await boot(tester, '/');
    final page = shellRoute(tester).settings as Page<Object?>;
    expect(page, isA<CupertinoPage<void>>());
    expect(page.key, const ValueKey<String>('layout:(tabs)/'));
    expect(page.restorationId, 'layout:(tabs)/');
  });

  testWidgets('switching routes inside the shell does not animate the shell',
      (tester) async {
    await boot(tester, '/');
    final route = shellRoute(tester);
    expect(route.animation!.status, AnimationStatus.completed);
    final bar = tester.getTopLeft(find.byType(NavigationBar));

    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Profile'),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(route.animation!.status, AnimationStatus.completed);
      expect(tester.getTopLeft(find.byType(NavigationBar)), bar);
    }
    await tester.pumpAndSettle();
    // The same route, not a new page pushed in its place.
    expect(identical(shellRoute(tester), route), isTrue);

    // Nor does a route inside a tab's own navigator.
    router.go('/profile/security');
    await tester.pumpAndSettle();
    expect(identical(shellRoute(tester), route), isTrue);
    expect(tester.getTopLeft(find.byType(NavigationBar)), bar);
  });

  testWidgets('the shell animates under a push on the root navigator',
      (tester) async {
    await boot(tester, '/');
    final bar = tester.getTopLeft(find.byType(NavigationBar));

    router.push('/settings');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // CupertinoPage moves the page below to the left while the new one slides in.
    expect(tester.getTopLeft(find.byType(NavigationBar)).dx, lessThan(bar.dx));

    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Settings'), findsWidgets);

    // Popping brings it back the same way, and it is still the same page.
    router.pop();
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.getTopLeft(find.byType(NavigationBar)), bar);
  });
}
