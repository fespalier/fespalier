import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';

late GoRouter router;

Future<void> boot(WidgetTester tester, String location) async {
  router = AppRoutes.router(initialLocation: location);
  await tester.pumpWidget(
    ProviderScope(
      // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
      // nesting both gives Material pages and error screens on either. The
      // inner app's localizations are material_ui's, so add flutter's for
      // the NavigationBar.
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

String get location => router.routeInformationProvider.value.uri.toString();

Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  ));
  await tester.pumpAndSettle();
}

void main() {
  int selected(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  testWidgets('starts on the first tab', (tester) async {
    await boot(tester, '/');
    expect(find.text('Home'), findsWidgets);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(selected(tester), 0);
    expect(location, '/');
  });

  testWidgets('tapping a tab changes the location and the page',
      (tester) async {
    await boot(tester, '/');

    await tapTab(tester, 'Search');
    expect(location, '/search');
    expect(find.text('Search count 0'), findsOneWidget);
    expect(selected(tester), 1);

    await tapTab(tester, 'Profile');
    expect(location, '/profile');
    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Search count 0'), findsNothing);
    expect(selected(tester), 2);

    await tapTab(tester, 'Home');
    expect(location, '/');
    expect(selected(tester), 0);
  });

  testWidgets('a tab keeps its state while you look at another one',
      (tester) async {
    await boot(tester, '/search');
    await tester.tap(find.byTooltip('+'));
    await tester.tap(find.byTooltip('+'));
    await tester.pump();
    expect(find.text('Search count 2'), findsOneWidget);

    await tapTab(tester, 'Profile');
    expect(find.text('Search count 2'), findsNothing);

    await tapTab(tester, 'Search');
    expect(location, '/search');
    expect(find.text('Search count 2'), findsOneWidget);
  });

  testWidgets('a tab keeps its own stack: /profile/edit stays open',
      (tester) async {
    await boot(tester, '/profile');
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    expect(location, '/profile/edit');

    await tapTab(tester, 'Home');
    expect(location, '/');
    await tapTab(tester, 'Profile');
    expect(location, '/profile/edit');
    expect(find.text('Edit profile'), findsOneWidget);
  });

  testWidgets('a nested route shows the bar with its tab selected',
      (tester) async {
    await boot(tester, '/profile/edit');
    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(selected(tester), 2);
  });

  testWidgets('a route outside the tabs is full screen', (tester) async {
    await boot(tester, '/settings');
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Settings'), findsWidgets);

    // And typed navigation gets you there from a tab.
    await boot(tester, '/profile');
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(location, '/settings');
    expect(find.byType(NavigationBar), findsNothing);
  });

  test('typed routes', () {
    expect(const HomeRoute().location, '/');
    expect(const SearchRoute().location, '/search');
    expect(const ProfileRoute().location, '/profile');
    expect(const EditProfileRoute().location, '/profile/edit');
    expect(const SettingsRoute().location, '/settings');
  });
}
