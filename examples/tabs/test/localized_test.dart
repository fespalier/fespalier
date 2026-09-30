// A localized tab: `(tabs)/search/route.dart` says `const paths = {'fr': 'recherche'};`.
// go_router opens a tab on its first route and can't do that for one with a path parameter,
// which is what a localized segment is, so `fsp gen` writes the tab's initialLocation.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';
import 'package:tabs/app.routes.g.dart';

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

String get location => router.routeInformationProvider.value.uri.toString();

Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

int selected(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

void main() {
  testWidgets('a deep link through the localized spelling opens the tab', (
    tester,
  ) async {
    await boot(tester, '/recherche');
    expect(find.text('Search count 0'), findsOneWidget);
    expect(selected(tester), 1);
    expect(location, '/recherche');
  });

  testWidgets('the canonical spelling opens the same tab', (tester) async {
    await boot(tester, '/search');
    expect(find.text('Search count 0'), findsOneWidget);
    expect(selected(tester), 1);
    expect(location, '/search');
  });

  testWidgets('the tab opens at its canonical location from another tab', (
    tester,
  ) async {
    await boot(tester, '/');
    await tapTab(tester, 'Search');
    expect(location, '/search');
    expect(find.text('Search count 0'), findsOneWidget);
    expect(selected(tester), 1);
  });

  testWidgets(
    'a tab reached by the localized spelling keeps it and its state',
    (tester) async {
      await boot(tester, '/recherche');
      await tester.tap(find.byTooltip('+'));
      await tester.pump();
      expect(find.text('Search count 1'), findsOneWidget);

      await tapTab(tester, 'Profile');
      expect(location, '/profile');
      await tapTab(tester, 'Search');
      expect(location, '/recherche');
      expect(find.text('Search count 1'), findsOneWidget);

      // Tapping the current tab goes back to its first page: the canonical location.
      await tapTab(tester, 'Search');
      expect(location, '/search');
    },
  );

  test('the typed route and the manifest know the spelling', () {
    expect(const SearchRoute().location, '/search');
    expect(const SearchRoute().locationFor('fr'), '/recherche');
    expect(const SearchRoute().locationFor('de'), '/search');
    expect(AppManifest.byType[SearchRoute]!.paths, {'fr': '/recherche'});
    expect(AppManifest.byType[ProfileRoute]!.paths, isEmpty);
    expect(AppManifest.match(Uri.parse('/recherche'))!.info.type, SearchRoute);
    expect(AppRoutes.dataAt(Uri.parse('/recherche')), isEmpty);
  });
}
