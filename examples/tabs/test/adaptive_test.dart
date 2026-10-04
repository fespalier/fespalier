// The tab layout as a bar, a rail or a drawer by window width (fespalier_adaptive), built from the
// six nav.dart files of this example through the generated AppMenu. tabs_test.dart is the same app
// in Flutter's default 800 x 600 window, which keeps the bar because the layout says `rail: 840`.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:tabs/app.g.dart';
import 'package:tabs/cross_fade.dart';

late GoRouter router;

/// Boots the app in a window [width] logical pixels wide (and tall enough for a drawer).
Future<void> boot(
  WidgetTester tester,
  String location, {
  required double width,
}) async {
  resize(tester, width);
  router = AppRoutes.router(initialLocation: location);
  await tester.pumpWidget(
    ProviderScope(
      // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's; nesting both gives
      // Material pages on either (see tabs_test.dart).
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

/// Sizes the window; a test's own is 800 x 600.
void resize(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

String get location => router.routeInformationProvider.value.uri.toString();

/// [label] inside the widget of type [T], not the page's own text.
Finder inside<T extends Widget>(String label) =>
    find.descendant(of: find.byType(T), matching: find.text(label));

void main() {
  testWidgets('a phone gets a bar, and the Library tab opens on Authors', (
    tester,
  ) async {
    await boot(tester, '/', width: 400);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationDrawer), findsNothing);

    // The destinations are the four tabs, named and drawn by their nav.dart files. Library is a
    // heading (it has no page), and it is a destination because it is a tab.
    for (final label in ['Home', 'Search', 'Profile', 'Library']) {
      expect(inside<NavigationBar>(label), findsOneWidget, reason: label);
    }
    expect(inside<NavigationBar>('Books'), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    // Selected: Icons.home; not selected: Icons.search.
    final icons = tester
        .widgetList<Icon>(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.byType(Icon),
          ),
        )
        .map((i) => i.icon);
    expect(icons, containsAll([Icons.home, Icons.search]));

    // goBranch to the tab, which opens where tabOptions says.
    await tester.tap(inside<NavigationBar>('Library'));
    await tester.pumpAndSettle();
    expect(location, '/library/authors');
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    // The chips of the Library layout are the menu below it, from an AdaptiveNavBuilder.
    expect(find.byType(ChoiceChip), findsNWidgets(2));

    // Flutter's default 800 x 600 window is a bar too (rail: 840), as tabs_test.dart relies on.
    await boot(tester, '/', width: 800);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets(
      'a tablet gets a rail, and a page on the root navigator covers it', (
    tester,
  ) async {
    await boot(tester, '/search', width: 1000);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationDrawer), findsNothing);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.selectedIndex, 1);
    expect(rail.labelType, NavigationRailLabelType.all);
    for (final label in ['Home', 'Search', 'Profile', 'Library']) {
      expect(inside<NavigationRail>(label), findsOneWidget, reason: label);
    }

    await tester.tap(inside<NavigationRail>('Profile'));
    await tester.pumpAndSettle();
    expect(location, '/profile');
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex,
      2,
    );

    // /profile/edit is on the root navigator (navigator.dart): it covers the rail, as it covers
    // a bar, and back shows the rail again.
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    expect(location, '/profile/edit');
    expect(find.text('Editing your profile'), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(location, '/profile');
    expect(find.byType(NavigationRail), findsOneWidget);
  });

  testWidgets(
      'a wide window gets a drawer with Books and Authors under Library', (
    tester,
  ) async {
    await boot(tester, '/library/authors', width: 1400);
    expect(find.byType(NavigationDrawer), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);

    // Library is the title of a section; Books and Authors are destinations, after Home, Search
    // and Profile. The deepest selected entry is Authors.
    final drawer = tester.widget<NavigationDrawer>(
      find.byType(NavigationDrawer),
    );
    expect(
      [
        for (final d
            in drawer.children.whereType<NavigationDrawerDestination>())
          ((d.label as Text).data),
      ],
      ['Home', 'Search', 'Profile', 'Books', 'Authors'],
    );
    expect(inside<NavigationDrawer>('Library'), findsOneWidget);
    expect(drawer.selectedIndex, 4);

    // Books has no tab of its own in this layout, so it is a plain navigation to its route; the
    // outer shell follows to the Library tab.
    await tester.tap(inside<NavigationDrawer>('Books'));
    await tester.pumpAndSettle();
    expect(location, '/library/books');
    expect(
      tester
          .widget<NavigationDrawer>(find.byType(NavigationDrawer))
          .selectedIndex,
      3,
    );

    await tester.tap(inside<NavigationDrawer>('Home'));
    await tester.pumpAndSettle();
    expect(location, '/');
    expect(
      tester
          .widget<NavigationDrawer>(find.byType(NavigationDrawer))
          .selectedIndex,
      0,
    );
    // The inner layout keeps its chips at every width: the builder gives the same model.
    await tester.tap(inside<NavigationDrawer>('Authors'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNWidgets(2));
  });

  testWidgets('a tab keeps its state when the window changes size', (
    tester,
  ) async {
    await boot(tester, '/search', width: 1000);
    expect(find.byType(NavigationRail), findsOneWidget);
    await tester.tap(find.byTooltip('+'));
    await tester.tap(find.byTooltip('+'));
    await tester.pump();
    expect(find.text('Search count 2'), findsOneWidget);

    // rail -> bar -> drawer -> rail: the tab's counter, its place in the cross-fade container
    // and the location do not change.
    for (final (width, component) in [
      (400.0, NavigationBar),
      (1400.0, NavigationDrawer),
      (1000.0, NavigationRail),
    ]) {
      resize(tester, width);
      await tester.pumpAndSettle();
      expect(find.byType(component), findsOneWidget, reason: 'at $width');
      expect(find.byType(CrossFadeContainer), findsOneWidget);
      expect(find.text('Search count 2'), findsOneWidget, reason: 'at $width');
      expect(location, '/search');
    }

    // A tab left behind keeps its state across a resize too: Books in the Library tab.
    await tester.tap(inside<NavigationRail>('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Books'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('+ book'));
    await tester.pump();
    await tester.tap(inside<NavigationRail>('Home'));
    await tester.pumpAndSettle();
    resize(tester, 400);
    await tester.pumpAndSettle();
    await tester.tap(inside<NavigationBar>('Library'));
    await tester.pumpAndSettle();
    expect(find.text('Books count 1'), findsOneWidget);
  });
}
