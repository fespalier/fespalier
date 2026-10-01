// `XRoute.of(context)` under tabs: each branch's page reads its own location, also while
// another tab is the one shown, and a layout above the tabs reads the whole location.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';
import 'package:tabs/app/(tabs)/(home)/page.dart';

Future<void> boot(WidgetTester tester, String location) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: mui.MaterialApp.router(
          routerConfig: AppRoutes.router(initialLocation: location),
          localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

BuildContext at(WidgetTester tester, String text) =>
    tester.element(find.text(text, skipOffstage: false));

void main() {
  testWidgets('the shown tab reads its route, the layout the location', (
    tester,
  ) async {
    await boot(tester, '/');
    expect(
        HomeRoute.of(tester.element(find.byType(HomePage))), isA<HomeRoute>());
    // The layout is above the tabs, so it reads the whole location.
    final layout = tester.element(find.byType(NavigationBar));
    expect(HomeRoute.maybeOf(layout), isNotNull);
    expect(SearchRoute.maybeOf(layout), isNull);
  });

  testWidgets('a tab that is built but not shown reads its own location', (
    tester,
  ) async {
    // Search is `preload: true`: built while Home is the tab shown.
    await boot(tester, '/');
    final search = at(tester, 'Search count 0');
    expect(SearchRoute.maybeOf(search), isNotNull);
    expect(HomeRoute.maybeOf(search), isNull);
  });

  testWidgets('the localized spelling of a tab is the same route', (
    tester,
  ) async {
    await boot(tester, '/recherche');
    final search = at(tester, 'Search count 0');
    expect(SearchRoute.of(search).location, '/search');
    expect(const SearchRoute().locationFor('fr'), '/recherche');
  });

  testWidgets('a page in a nested tab layout reads its own route', (
    tester,
  ) async {
    await boot(tester, '/library/books');
    expect(BooksRoute.of(at(tester, 'Books count 0')), isA<BooksRoute>());
    expect(AuthorsRoute.maybeOf(at(tester, 'Books count 0')), isNull);
  });
}
