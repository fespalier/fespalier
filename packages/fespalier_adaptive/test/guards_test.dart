// Guards decide what the scaffold lists, through whatever AppMenu.watch answers: a hidden entry is
// absent, a disabled one is listed and off, and the destinations are mapped through their tab, so
// a tap after another entry went away still lands on the right page.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/nav.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_adaptive/material.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class Flag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final signedIn = NotifierProvider<Flag, bool>(Flag.new);

/// The guard `guard.dart` files are: a location to go to instead, or null.
GuardResult signInGuard(Ref ref, TypedLocation route) =>
    ref.watch(signedIn) ? null : '/login';

const guardedSearch = NavNode(
  folder: '(tabs)/search',
  nav: Nav(label: 'Search', icon: Icons.search),
  route: searchAt,
  guard: signInGuard,
  tabs: {'(tabs)': 1},
);
const disabledProfile = NavNode(
  folder: '(tabs)/profile',
  nav: Nav(label: 'Profile', whenRefused: NavRefused.disable),
  route: profileAt,
  guard: signInGuard,
  tabs: {'(tabs)': 2},
);

const guardedTree = [home, guardedSearch, disabledProfile, library];

void main() {
  Future<ProviderContainer> boot(WidgetTester tester, double width) {
    resize(tester, width);
    return pumpRouter(
      tester,
      tabsRouter('/', layout: scaffoldFor(guardedTree)),
    );
  }

  testWidgets('a refused entry is hidden, and it comes back with the guard', (
    tester,
  ) async {
    final container = await boot(tester, 400);
    // Signed out: Search is hidden, Profile is listed and off.
    expect(inside<NavigationBar>('Search'), findsNothing);
    expect(inside<NavigationBar>('Profile'), findsOneWidget);
    expect(inside<NavigationBar>('Library'), findsOneWidget);

    container.read(signedIn.notifier).set(true);
    await tester.pump();
    // The next frame, with no navigation.
    expect(inside<NavigationBar>('Search'), findsOneWidget);
    expect(currentLocation(tester), '/');

    container.read(signedIn.notifier).set(false);
    await tester.pump();
    expect(inside<NavigationBar>('Search'), findsNothing);
    expect(currentLocation(tester), '/');
  });

  testWidgets(
    'taps go through the tab, not the position, after an entry went away',
    (tester) async {
      await boot(tester, 400);
      final labels = [
        for (final d in tester.widgetList<NavigationDestination>(
          find.byType(NavigationDestination),
        ))
          d.label,
      ];
      // Search (tab 1) is out, so Profile (tab 2) is the second destination.
      expect(labels, ['Home', 'Profile', 'Library']);
      // Profile is disabled: a tap does nothing.
      await tester.tap(inside<NavigationBar>('Profile'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/');

      // Library (tab 3) is the third destination.
      await tester.tap(inside<NavigationBar>('Library'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/library/books');
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
    },
  );

  testWidgets(
    'NavRefused.disable lists the entry and turns it off, in each component',
    (tester) async {
      final container = await boot(tester, 400);
      bool? barEnabled(String label) => tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .where((d) => d.label == label)
          .map((d) => d.enabled)
          .firstOrNull;
      expect(barEnabled('Profile'), isFalse);
      expect(barEnabled('Home'), isTrue);

      resize(tester, 700);
      await tester.pumpAndSettle();
      var rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      // Home, Profile and Library: Search is hidden.
      expect(
        [for (final d in rail.destinations) d.disabled],
        [false, true, false],
      );

      resize(tester, 1300);
      await tester.pumpAndSettle();
      final drawer = tester.widgetList<NavigationDrawerDestination>(
        find.byType(NavigationDrawerDestination),
      );
      expect(
        [for (final d in drawer) d.enabled],
        [
          true, // Home
          false, // Profile
          true, // Books
          true, // Authors
        ],
      );

      // Signing in turns it on, and lists Search.
      container.read(signedIn.notifier).set(true);
      resize(tester, 700);
      await tester.pumpAndSettle();
      rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(4));
      expect([
        for (final d in rail.destinations) d.disabled,
      ], everyElement(isFalse));
    },
  );

  testWidgets('a refused tap on a disabled rail destination does nothing', (
    tester,
  ) async {
    await boot(tester, 700);
    await tester.tap(inside<NavigationRail>('Profile'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
    expect(lastShell!.currentIndex, 0);
  });

  testWidgets(
    'the model says the same: enabled follows the access of the entry',
    (tester) async {
      late AdaptiveNav seen;
      resize(tester, 400);
      final container = await pumpRouter(
        tester,
        tabsRouter(
          '/',
          layout: (shell) => AdaptiveNavBuilder(
            menu: menuOf(guardedTree),
            shell: shell,
            builder: (context, nav) {
              seen = nav;
              return shell;
            },
          ),
        ),
      );
      expect(
        [for (final d in seen.destinations) d.nav.label],
        ['Home', 'Profile', 'Library'],
      );
      expect(
        [for (var i = 0; i < 3; i++) seen.enabled(i)],
        [true, false, true],
      );
      container.read(signedIn.notifier).set(true);
      await tester.pump();
      expect(seen.destinations, hasLength(4));
      expect([
        for (var i = 0; i < 4; i++) seen.enabled(i),
      ], everyElement(isTrue));
    },
  );
}
