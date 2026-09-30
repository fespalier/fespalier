import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';
import 'package:tabs/cross_fade.dart';

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
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
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

  testWidgets('tapping a tab changes the location and the page', (
    tester,
  ) async {
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

  testWidgets('a tab keeps its state while you look at another one', (
    tester,
  ) async {
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

  testWidgets('a tab keeps its own stack: /profile/security stays open', (
    tester,
  ) async {
    await boot(tester, '/profile');
    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    expect(location, '/profile/security');

    await tapTab(tester, 'Home');
    expect(location, '/');
    await tapTab(tester, 'Profile');
    expect(location, '/profile/security');
    expect(find.text('Security'), findsOneWidget);
  });

  testWidgets('a nested route shows the bar with its tab selected', (
    tester,
  ) async {
    await boot(tester, '/profile/security');
    expect(find.text('Security'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(selected(tester), 2);
  });

  group('navigator.dart: a route on the root navigator', () {
    // /profile/edit is under /profile in the URL, and full screen.
    testWidgets('renders above the tab bar, and back returns to the tab', (
      tester,
    ) async {
      await boot(tester, '/profile');
      await tester.tap(find.text('Edit profile'));
      await tester.pumpAndSettle();
      expect(location, '/profile/edit');
      expect(find.text('Editing your profile'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // The root navigator holds the page, the tab layout's navigator does not.
      final edit = tester.element(find.text('Editing your profile'));
      expect(Navigator.of(edit), AppRoutes.rootNavigatorKey.currentState);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(location, '/profile');
      expect(find.text('Editing your profile'), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(selected(tester), 2);
      expect(find.text('Profile'), findsWidgets);
    });

    testWidgets('a deep link builds the tab page underneath', (tester) async {
      await boot(tester, '/profile/edit');
      expect(find.text('Editing your profile'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      // The Profile tab is built below it, hidden by the page above.
      expect(find.text('Profile', skipOffstage: false), findsWidgets);
      expect(find.byType(NavigationBar, skipOffstage: false), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(location, '/profile');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(selected(tester), 2);
    });

    testWidgets('the app can read and supply the root navigator key', (
      tester,
    ) async {
      await boot(tester, '/');
      expect(AppRoutes.rootNavigatorKey.currentState, isNotNull);
      expect(router.configuration.navigatorKey, AppRoutes.rootNavigatorKey);

      final key = GlobalKey<NavigatorState>();
      final mine = AppRoutes.router(navigatorKey: key);
      expect(AppRoutes.rootNavigatorKey, key);
      expect(mine.configuration.navigatorKey, key);
    });
  });

  group('container: a custom branch container', () {
    testWidgets('cross-fades between tabs, each keeping its state', (
      tester,
    ) async {
      await boot(tester, '/search');
      expect(find.byType(CrossFadeContainer), findsOneWidget);
      await tester.tap(find.byTooltip('+'));
      await tester.pump();
      expect(find.text('Search count 1'), findsOneWidget);

      // Half way through the fade both tabs are painted.
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Profile'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Search count 1'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('Search count 1'), findsNothing);
      expect(find.text('Security'), findsOneWidget);

      await tapTab(tester, 'Search');
      expect(find.text('Search count 1'), findsOneWidget);
    });
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

  group('nested tabs and tab options', () {
    Future<void> tapInner(WidgetTester tester, String label) async {
      await tester.tap(find.widgetWithText(ChoiceChip, label));
      await tester.pumpAndSettle();
    }

    bool chipSelected(WidgetTester tester, String label) => tester
        .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label))
        .selected;

    testWidgets('initialLocation: the Library tab opens on Authors', (
      tester,
    ) async {
      await boot(tester, '/');
      await tapTab(tester, 'Library');
      expect(location, '/library/authors');
      expect(find.text('Authors list'), findsOneWidget);
      expect(selected(tester), 3);
      expect(chipSelected(tester, 'Authors'), isTrue);

      // The tab's own location still works as a deep link.
      await boot(tester, '/library/books');
      expect(find.text('Books count 0'), findsOneWidget);
      expect(selected(tester), 3);
      expect(chipSelected(tester, 'Books'), isTrue);
    });

    testWidgets('an inner tab keeps its state, inside a kept outer tab', (
      tester,
    ) async {
      await boot(tester, '/library/books');
      await tester.tap(find.byTooltip('+ book'));
      await tester.tap(find.byTooltip('+ book'));
      await tester.pump();
      expect(find.text('Books count 2'), findsOneWidget);

      // Switching inner tabs leaves the counter alone...
      await tapInner(tester, 'Authors');
      expect(location, '/library/authors');
      expect(find.text('Books count 2'), findsNothing);
      await tapInner(tester, 'Books');
      expect(location, '/library/books');
      expect(find.text('Books count 2'), findsOneWidget);

      // ...and so does switching outer tabs, and coming back to the same
      // inner tab.
      await tapTab(tester, 'Search');
      expect(location, '/search');
      expect(find.text('Books count 2'), findsNothing);
      await tapTab(tester, 'Library');
      expect(location, '/library/books');
      expect(find.text('Books count 2'), findsOneWidget);

      // The inner shell remembers which inner tab was showing, too.
      await tapInner(tester, 'Authors');
      await tapTab(tester, 'Home');
      await tapTab(tester, 'Library');
      expect(location, '/library/authors');
      await tapInner(tester, 'Books');
      expect(find.text('Books count 2'), findsOneWidget);
    });

    testWidgets('preload builds a tab before it is visited', (tester) async {
      // Search is preloaded by the outer layout...
      await boot(tester, '/');
      expect(find.text('Search count 0'), findsNothing);
      expect(find.text('Search count 0', skipOffstage: false), findsOneWidget);

      // ...and Books by the inner one, when Library opens on Authors. Profile
      // is not preloaded.
      await boot(tester, '/library/authors');
      expect(find.text('Authors list'), findsOneWidget);
      expect(find.text('Books count 0'), findsNothing);
      expect(find.text('Books count 0', skipOffstage: false), findsOneWidget);
      expect(find.text('Edit profile', skipOffstage: false), findsNothing);
    });

    testWidgets('an inner tab is not full screen: the outer bar stays', (
      tester,
    ) async {
      await boot(tester, '/library/authors');
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(2));
    });

    test('typed routes', () {
      expect(const BooksRoute().location, '/library/books');
      expect(const AuthorsRoute().location, '/library/authors');
    });
  });

  test('typed routes', () {
    expect(const HomeRoute().location, '/');
    expect(const SearchRoute().location, '/search');
    expect(const ProfileRoute().location, '/profile');
    expect(const EditProfileRoute().location, '/profile/edit');
    expect(const SecurityRoute().location, '/profile/security');
    expect(const SettingsRoute().location, '/settings');
  });
}
