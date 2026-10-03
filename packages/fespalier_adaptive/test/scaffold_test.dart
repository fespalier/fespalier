// AdaptiveNavScaffold on a hand-built tab layout (support.dart): which component each width
// shows, that a page keeps its state when the window changes size, and the slots.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/nav.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_adaptive/material.dart';
import 'package:fespalier_adaptive/src/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUp(debugResetAdaptiveReports);

  /// Runs [body] with `debugPrint` collecting what this package prints (the framework may print
  /// too). The test restores it itself: the binding checks it before any tearDown runs.
  Future<void> capture(
    Future<void> Function(List<String> Function() ours) body,
  ) async {
    final original = debugPrint;
    final printed = <String>[];
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    try {
      await body(
        () => [
          for (final m in printed)
            if (m.startsWith('fespalier_adaptive:')) m,
        ],
      );
    } finally {
      debugPrint = original;
    }
  }

  Future<void> boot(
    WidgetTester tester,
    String at, {
    double width = 400,
    Widget Function(StatefulNavigationShell shell)? layout,
  }) async {
    resize(tester, width);
    await pumpRouter(tester, tabsRouter(at, layout: layout));
  }

  group('a tab layout', () {
    testWidgets('is a bar under 600', (tester) async {
      await boot(tester, '/search', width: 400);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationDrawer), findsNothing);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
      // The top-level entries: Library is a destination (it is a tab), Books and Authors are not.
      for (final label in ['Home', 'Search', 'Profile', 'Library']) {
        expect(inside<NavigationBar>(label), findsOneWidget, reason: label);
      }
      expect(inside<NavigationBar>('Books'), findsNothing);
    });

    testWidgets('is a rail from 600 to 1199, with every label', (tester) async {
      await boot(tester, '/search', width: 700);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byType(NavigationDrawer), findsNothing);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.selectedIndex, 1);
      expect(rail.labelType, NavigationRailLabelType.all);
      for (final label in ['Home', 'Search', 'Profile', 'Library']) {
        expect(inside<NavigationRail>(label), findsOneWidget, reason: label);
      }
      expect(inside<NavigationRail>('Books'), findsNothing);
    });

    testWidgets(
      'is a drawer from 1200, with a section title over Books and Authors',
      (tester) async {
        await boot(tester, '/library/authors', width: 1300);
        expect(find.byType(NavigationDrawer), findsOneWidget);
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.byType(NavigationRail), findsNothing);
        final drawer = tester.widget<NavigationDrawer>(
          find.byType(NavigationDrawer),
        );
        // Home, Search, Profile, Books, Authors: the deepest selected entry is Authors.
        expect(
          drawer.children.whereType<NavigationDrawerDestination>(),
          hasLength(5),
        );
        expect(drawer.selectedIndex, 4);
        // Library is the title of a section, not a destination of its own.
        expect(inside<NavigationDrawer>('Library'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(NavigationDrawer),
            matching: find.byType(NavigationDrawerDestination),
          ),
          findsNWidgets(5),
        );
        expect(inside<NavigationDrawer>('Books'), findsOneWidget);
        expect(inside<NavigationDrawer>('Authors'), findsOneWidget);
      },
    );

    testWidgets('the drawer is flat and square beside the body', (
      tester,
    ) async {
      await boot(tester, '/', width: 1300);
      final drawer = tester.widget<Drawer>(find.byType(Drawer));
      expect(drawer.elevation, 0);
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(Drawer),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.shape, const RoundedRectangleBorder());
    });

    testWidgets('the breakpoints are the app\'s', (tester) async {
      await boot(
        tester,
        '/',
        width: 700,
        layout: scaffoldFor(
          tabsTree,
          breakpoints: const NavBreakpoints(rail: 840),
        ),
      );
      expect(find.byType(NavigationBar), findsOneWidget);
      resize(tester, 900);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('tapping a destination switches the tab, in each component', (
      tester,
    ) async {
      await boot(tester, '/', width: 400);
      await tester.tap(inside<NavigationBar>('Search'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/search');
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );

      resize(tester, 700);
      await tester.pumpAndSettle();
      await tester.tap(inside<NavigationRail>('Profile'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/profile');
      expect(
        tester
            .widget<NavigationRail>(find.byType(NavigationRail))
            .selectedIndex,
        2,
      );

      resize(tester, 1300);
      await tester.pumpAndSettle();
      await tester.tap(inside<NavigationDrawer>('Authors'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/library/authors');
      expect(
        tester
            .widget<NavigationDrawer>(find.byType(NavigationDrawer))
            .selectedIndex,
        4,
      );

      await tester.tap(inside<NavigationDrawer>('Home'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/');
    });

    testWidgets(
      'a tab keeps its state from a bar to a rail to a drawer and back',
      (tester) async {
        await boot(tester, '/search', width: 400);
        await tester.tap(find.byTooltip('+ Search'));
        await tester.tap(find.byTooltip('+ Search'));
        await tester.pump();
        expect(find.text('Search count 2'), findsOneWidget);

        for (final width in [1000.0, 1400.0, 400.0]) {
          resize(tester, width);
          await tester.pumpAndSettle();
          expect(
            find.text('Search count 2'),
            findsOneWidget,
            reason: 'at $width',
          );
        }
        // The other tabs kept theirs too: Home was never visited, Search is still counting.
        await tester.tap(find.byTooltip('+ Search'));
        await tester.pump();
        expect(find.text('Search count 3'), findsOneWidget);
      },
    );

    testWidgets('a tab left behind keeps its state across a resize too', (
      tester,
    ) async {
      await boot(tester, '/search', width: 400);
      await tester.tap(find.byTooltip('+ Search'));
      await tester.pump();
      await tester.tap(inside<NavigationBar>('Profile'));
      await tester.pumpAndSettle();
      resize(tester, 1400);
      await tester.pumpAndSettle();
      await tester.tap(inside<NavigationDrawer>('Search'));
      await tester.pumpAndSettle();
      expect(find.text('Search count 1'), findsOneWidget);
    });
  });

  testWidgets(
    'the body keeps its state from a bar to a rail to a drawer even when nothing else keys it',
    (tester) async {
      // A page with no navigator of go_router's around it (whose global keys would carry its state
      // anyway): only the body's own place in the tree keeps it.
      resize(tester, 400);
      final menu = [
        entry('Home', route: const HomeRoute(), selected: true),
        entry('Search', route: const SearchRoute()),
      ];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AdaptiveNavScaffold(
              menu: (ref) => menu,
              child: const Counter('Body'),
            ),
          ),
        ),
      );
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.tap(find.byTooltip('+ Body'));
      await tester.pump();
      for (final (width, component) in [
        (700.0, NavigationRail),
        (1400.0, NavigationDrawer),
        (400.0, NavigationBar),
        (1400.0, NavigationDrawer),
      ]) {
        resize(tester, width);
        await tester.pumpAndSettle();
        expect(find.byType(component), findsOneWidget, reason: 'at $width');
        expect(find.text('Body count 1'), findsOneWidget, reason: 'at $width');
      }
    },
  );

  group('a plain layout', () {
    GoRouter plain(String at) => GoRouter(
      initialLocation: at,
      routes: [
        ShellRoute(
          builder: (context, state, child) =>
              AdaptiveNavScaffold(menu: menuOf(tabsTree), child: child),
          routes: [
            GoRoute(path: '/', builder: (_, _) => const Counter('Home')),
            GoRoute(
              path: '/search',
              builder: (_, _) => const Counter('Search'),
            ),
            GoRoute(
              path: '/profile',
              builder: (_, _) => const Counter('Profile'),
            ),
          ],
        ),
      ],
    );

    testWidgets('keeps its page\'s state from a bar to a rail to a drawer', (
      tester,
    ) async {
      resize(tester, 400);
      await pumpRouter(tester, plain('/search'));
      // Without a shell nothing has a tab: the entries go by the page.
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.tap(find.byTooltip('+ Search'));
      await tester.pump();
      for (final width in [700.0, 1400.0, 400.0]) {
        resize(tester, width);
        await tester.pumpAndSettle();
        expect(
          find.text('Search count 1'),
          findsOneWidget,
          reason: 'at $width',
        );
      }
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
    });

    testWidgets('tapping goes to the entry\'s route', (tester) async {
      resize(tester, 400);
      await pumpRouter(tester, plain('/'));
      await tester.tap(inside<NavigationBar>('Profile'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/profile');
    });
  });

  group('slots', () {
    Widget badged(BuildContext context, NavItem item, bool selected) => Badge(
      label: const Text('3'),
      child: defaultNavIcon(context, item, selected),
    );

    for (final (width, component, expected) in [
      (400.0, NavigationBar, ['Home', 'Search', 'Profile', 'Library']),
      (700.0, NavigationRail, ['Home', 'Search', 'Profile', 'Library']),
      (
        1300.0,
        NavigationDrawer,
        ['Home', 'Search', 'Profile', 'Books', 'Authors'],
      ),
    ]) {
      testWidgets('icon: builds the icon of every destination in a $component', (
        tester,
      ) async {
        final built = <String>{};
        await boot(
          tester,
          '/',
          width: width,
          layout: (shell) => AdaptiveNavScaffold(
            shell: shell,
            menu: menuOf(tabsTree),
            icon: (context, item, selected) {
              built.add(item.nav.label);
              return badged(context, item, selected);
            },
          ),
        );
        // A bar and a rail take an icon for each state; the drawer lists Books and Authors, not
        // the Library heading.
        expect(built, expected.toSet());
        expect(
          find.descendant(
            of: find.byType(component),
            matching: find.byType(Badge),
          ),
          findsWidgets,
        );
      });
    }

    testWidgets('the default icon is the selected one while selected', (
      tester,
    ) async {
      await boot(tester, '/', width: 400);
      // Home is selected: Icons.home, not Icons.home_outlined; Search is not.
      final icons = tester
          .widgetList<Icon>(
            find.descendant(
              of: find.byType(NavigationBar),
              matching: find.byType(Icon),
            ),
          )
          .map((i) => i.icon)
          .toList();
      expect(icons, contains(Icons.home));
      expect(icons, isNot(contains(Icons.home_outlined)));
      expect(icons, contains(Icons.search));
    });

    for (final (width, shown) in [
      (400.0, false),
      (700.0, true),
      (1300.0, true),
    ]) {
      testWidgets('leading is ${shown ? '' : 'not '}shown at $width', (
        tester,
      ) async {
        await boot(
          tester,
          '/',
          width: width,
          layout: (shell) => AdaptiveNavScaffold(
            shell: shell,
            menu: menuOf(tabsTree),
            leading: (context, nav) => Text('logo ${nav.mode.name}'),
            trailing: (context, nav) => const Text('footer'),
          ),
        );
        expect(
          find.textContaining('logo'),
          shown ? findsOneWidget : findsNothing,
        );
        expect(find.text('footer'), shown ? findsOneWidget : findsNothing);
      });
    }

    testWidgets('floatingActionButton is asked in every mode', (tester) async {
      final modes = <NavMode>[];
      Widget layout(StatefulNavigationShell shell) => AdaptiveNavScaffold(
        shell: shell,
        menu: menuOf(tabsTree),
        floatingActionButton: (context, nav) {
          modes.add(nav.mode);
          // Where the button went into `leading`, there is none here.
          return nav.mode == NavMode.bar
              ? FloatingActionButton(
                  onPressed: () {},
                  child: const Icon(Icons.edit),
                )
              : null;
        },
      );
      await boot(tester, '/', width: 400, layout: layout);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      resize(tester, 700);
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(modes, containsAll([NavMode.bar, NavMode.rail]));
    });

    testWidgets('exactly one of shell: and child: is asserted', (tester) async {
      expect(
        () => AdaptiveNavScaffold(menu: menuOf(tabsTree)),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message,
            'message',
            'AdaptiveNavScaffold takes shell: (a tab layout) or child: (a plain layout), exactly one of them.',
          ),
        ),
      );
      expect(
        () => AdaptiveNavScaffold(
          menu: menuOf(tabsTree),
          child: const SizedBox(),
        ),
        returnsNormally,
      );
    });
  });

  group('when no component is shown', () {
    testWidgets('one destination is no bar and no rail', (tester) async {
      await capture((ours) async {
        for (final width in [400.0, 700.0, 1300.0]) {
          await boot(
            tester,
            '/',
            width: width,
            layout: scaffoldFor(const [home]),
          );
          expect(find.byType(NavigationBar), findsNothing, reason: 'at $width');
          expect(
            find.byType(NavigationRail),
            findsNothing,
            reason: 'at $width',
          );
          expect(
            find.byType(NavigationDrawer),
            findsNothing,
            reason: 'at $width',
          );
          // The body is shown alone.
          expect(find.text('Home count 0'), findsOneWidget);
        }
        // Nothing is wrong with the layout: the one entry is the current tab.
        expect(ours(), isEmpty);
      });
    });

    testWidgets('a page no entry covers hides the bar and says so once', (
      tester,
    ) async {
      await capture((ours) async {
        // The Library tab has no entry here, as when its folder has no nav.dart.
        await boot(
          tester,
          '/library/books',
          width: 400,
          layout: scaffoldFor(const [home, search, profile]),
        );
        expect(find.byType(NavigationBar), findsNothing);
        expect(find.text('Books count 0'), findsOneWidget);
        expect(ours(), [noTabEntryMessage(3)]);
        expect(
          noTabEntryMessage(3),
          'fespalier_adaptive: no menu entry is the current tab (3) of the tab layout, so the '
          "navigation bar is hidden. Give the tab's folder a nav.dart (not inMenu: false), and pass "
          "AppMenu.watch(ref, under: <the tab layout's folder>).",
        );

        // Rebuilds, a resize and a navigation do not repeat it.
        resize(tester, 401);
        await tester.pumpAndSettle();
        lastShell!.goBranch(0);
        await tester.pumpAndSettle();
        lastShell!.goBranch(3);
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsNothing);
        expect(ours(), hasLength(1));
      });
    });

    testWidgets(
      'a rail and a drawer show none selected on that page, and no message',
      (tester) async {
        await capture((ours) async {
          for (final width in [700.0, 1300.0]) {
            await boot(
              tester,
              '/library/books',
              width: width,
              layout: scaffoldFor(const [home, search, profile]),
            );
            final selected = width < 1200
                ? tester
                      .widget<NavigationRail>(find.byType(NavigationRail))
                      .selectedIndex
                : tester
                      .widget<NavigationDrawer>(find.byType(NavigationDrawer))
                      .selectedIndex;
            expect(selected, isNull, reason: 'at $width');
            expect(find.text('Books count 0'), findsOneWidget);
          }
          // Only a bar is hidden by it, so only a bar's page is told.
          expect(ours(), isEmpty);
        });
      },
    );

    testWidgets('the bar comes back when the page is covered again', (
      tester,
    ) async {
      await capture((ours) async {
        await boot(
          tester,
          '/library/books',
          width: 400,
          layout: scaffoldFor(const [home, search, profile]),
        );
        expect(find.byType(NavigationBar), findsNothing);
        lastShell!.goBranch(1);
        await tester.pumpAndSettle();
        expect(find.byType(NavigationBar), findsOneWidget);
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          1,
        );
      });
    });
  });

  testWidgets('the model builder gives the same model without Material', (
    tester,
  ) async {
    late AdaptiveNav seen;
    await boot(
      tester,
      '/search',
      width: 700,
      layout: (shell) => AdaptiveNavBuilder(
        menu: menuOf(tabsTree),
        shell: shell,
        builder: (context, nav) {
          seen = nav;
          return shell;
        },
      ),
    );
    expect(seen.mode, NavMode.rail);
    expect(seen.width, 700);
    expect(seen.selectedIndex, 1);
    expect(
      [for (final d in seen.destinations) d.nav.label],
      ['Home', 'Search', 'Profile', 'Library'],
    );
    resize(tester, 1300);
    await tester.pumpAndSettle();
    expect(seen.mode, NavMode.drawer);
    expect(
      [for (final d in seen.destinations) d.nav.label],
      ['Home', 'Search', 'Profile', 'Books', 'Authors'],
    );
  });
}
