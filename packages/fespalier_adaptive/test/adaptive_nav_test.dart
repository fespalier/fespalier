// The model, rule by rule (docs/layouts.md, "A bar, a rail or a drawer"): NavItems are built by hand, and a
// real StatefulShellRoute router is there where a shell is needed.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/nav.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_adaptive/fespalier_adaptive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Pumps the tabs router with the shell alone as the layout, and gives the shell.
Future<StatefulNavigationShell> pumpShell(
  WidgetTester tester, {
  String at = '/',
}) async {
  await pumpRouter(tester, tabsRouter(at, layout: (shell) => shell));
  return lastShell!;
}

void main() {
  group('the bar and the rail', () {
    final books = entry('Books', route: const BooksRoute());
    final authors = entry('Authors', route: const AuthorsRoute());

    testWidgets(
      'a heading with a tab is a destination with a shell, and not without',
      (tester) async {
        final shell = await pumpShell(tester);
        final menu = [
          entry('Home', route: const HomeRoute(), tab: 0),
          entry('Library', tab: 3, children: [books, authors]),
        ];
        final withShell = AdaptiveNav(menu: menu, width: 400, shell: shell);
        expect(labels(withShell.destinations), ['Home', 'Library']);

        // Without a shell nothing switches tabs, so the heading goes nowhere: its children stand in.
        final without = AdaptiveNav(menu: menu, width: 400);
        expect(labels(without.destinations), ['Home', 'Books', 'Authors']);
      },
    );

    testWidgets('a heading without a tab is replaced by its children', (
      tester,
    ) async {
      final shell = await pumpShell(tester);
      final menu = [
        entry('Home', route: const HomeRoute(), tab: 0),
        entry('Library', children: [books, authors]),
      ];
      for (final nav in [
        AdaptiveNav(menu: menu, width: 400, shell: shell),
        AdaptiveNav(menu: menu, width: 400),
        AdaptiveNav(menu: menu, width: 700, shell: shell),
      ]) {
        expect(labels(nav.destinations), ['Home', 'Books', 'Authors']);
      }
    });

    test(
      'an entry with a route is one destination: its children are not listed',
      () {
        final menu = [
          entry(
            'Products',
            route: const SearchRoute(),
            children: [entry('Categories', route: const BooksRoute())],
          ),
          entry('Cart', route: const ProfileRoute()),
        ];
        for (final width in [400.0, 700.0]) {
          final nav = AdaptiveNav(menu: menu, width: width);
          expect(labels(nav.destinations), ['Products', 'Cart']);
        }
      },
    );

    test('they are one top-level section', () {
      final nav = AdaptiveNav(
        menu: [
          entry('A', route: const HomeRoute()),
          entry('B', route: const SearchRoute()),
        ],
        width: 700,
      );
      expect(nav.mode, NavMode.rail);
      expect(nav.sections, hasLength(1));
      expect(nav.sections.single.heading, isNull);
      expect(nav.sections.single.start, 0);
      expect(nav.sections.single.end, 2);
    });

    test(
      'a heading with nothing under it that goes nowhere is no destination',
      () {
        final nav = AdaptiveNav(
          menu: [
            entry('Home', route: const HomeRoute()),
            entry('Empty'),
            entry('Search', route: const SearchRoute()),
          ],
          width: 400,
        );
        expect(labels(nav.destinations), ['Home', 'Search']);
      },
    );
  });

  group('the drawer', () {
    testWidgets(
      'lists every entry that goes somewhere, a heading as a section title',
      (tester) async {
        final shell = await pumpShell(tester, at: '/library/authors');
        final library = entry(
          'Library',
          tab: 3,
          selected: true,
          children: [
            entry('Books', route: const BooksRoute()),
            entry('Authors', route: const AuthorsRoute(), selected: true),
          ],
        );
        final nav = AdaptiveNav(
          menu: [
            entry('Home', route: const HomeRoute(), tab: 0),
            entry('Search', route: const SearchRoute(), tab: 1),
            entry('Profile', route: const ProfileRoute(), tab: 2),
            library,
          ],
          width: 1300,
          shell: shell,
        );
        expect(nav.mode, NavMode.drawer);
        expect(labels(nav.destinations), [
          'Home',
          'Search',
          'Profile',
          'Books',
          'Authors',
        ]);
        expect(nav.sections, hasLength(2));
        expect(nav.sections[0].heading, isNull);
        expect([nav.sections[0].start, nav.sections[0].end], [0, 3]);
        expect(nav.sections[1].heading, same(library));
        expect([nav.sections[1].start, nav.sections[1].end], [3, 5]);
        // The deepest selected entry with a route: Authors, not Library (a heading, selected too).
        expect(nav.selectedIndex, 4);
      },
    );

    test('the deepest selected entry wins over the route it is below', () {
      final nav = AdaptiveNav(
        menu: [
          entry('Home', route: const HomeRoute()),
          entry(
            'Products',
            route: const SearchRoute(),
            selected: true,
            children: [
              entry('Sale', route: const BooksRoute(), selected: true),
              entry('New', route: const AuthorsRoute()),
            ],
          ),
        ],
        width: 1300,
      );
      expect(labels(nav.destinations), ['Home', 'Products', 'Sale', 'New']);
      // A route's children stay in its section.
      expect(nav.sections, hasLength(1));
      expect(nav.selectedIndex, 2);
    });

    test(
      'an entry after a heading is a section of its own, without a title',
      () {
        final nav = AdaptiveNav(
          menu: [
            entry('Home', route: const HomeRoute()),
            entry(
              'Library',
              children: [entry('Books', route: const BooksRoute())],
            ),
            entry('Profile', route: const ProfileRoute()),
          ],
          width: 1300,
        );
        expect(
          [
            for (final s in nav.sections)
              (s.heading?.nav.label, s.start, s.end),
          ],
          [(null, 0, 1), ('Library', 1, 2), (null, 2, 3)],
        );
      },
    );

    test('headings below headings are flattened into sections in order', () {
      final nav = AdaptiveNav(
        menu: [
          entry(
            'A',
            children: [
              entry('B', children: [entry('One', route: const HomeRoute())]),
              entry('Two', route: const SearchRoute()),
            ],
          ),
        ],
        width: 1300,
      );
      expect(labels(nav.destinations), ['One', 'Two']);
      expect(
        [for (final s in nav.sections) (s.heading?.nav.label, s.start, s.end)],
        [('B', 0, 1), ('A', 1, 2)],
      );
    });

    testWidgets(
      'a heading that is a tab and has nothing below it is a destination',
      (tester) async {
        final shell = await pumpShell(tester);
        final menu = [
          entry('Home', route: const HomeRoute(), tab: 0),
          entry('Library', tab: 3),
        ];
        final nav = AdaptiveNav(menu: menu, width: 1300, shell: shell);
        expect(labels(nav.destinations), ['Home', 'Library']);
        // Without a shell it goes nowhere.
        expect(labels(AdaptiveNav(menu: menu, width: 1300).destinations), [
          'Home',
        ]);
      },
    );

    testWidgets('with no selected entry the current tab is selected', (
      tester,
    ) async {
      final shell = await pumpShell(tester, at: '/profile');
      final nav = AdaptiveNav(
        menu: [
          entry('Home', route: const HomeRoute(), tab: 0),
          entry('Search', route: const SearchRoute(), tab: 1),
          entry('Profile', route: const ProfileRoute(), tab: 2),
        ],
        width: 1300,
        shell: shell,
      );
      expect(shell.currentIndex, 2);
      expect(nav.selectedIndex, 2);
    });
  });

  group('selection', () {
    testWidgets(
      'a shell selects by tab, whatever the entries say about the page',
      (tester) async {
        final shell = await pumpShell(tester, at: '/search');
        final menu = [
          // `selected` is about the location; the tab is what the shell shows.
          entry('Home', route: const HomeRoute(), tab: 0, selected: true),
          entry('Search', route: const SearchRoute(), tab: 1),
          entry('Profile', route: const ProfileRoute(), tab: 2),
        ];
        expect(
          AdaptiveNav(menu: menu, width: 400, shell: shell).selectedIndex,
          1,
        );
        expect(
          AdaptiveNav(menu: menu, width: 700, shell: shell).selectedIndex,
          1,
        );
      },
    );

    testWidgets('a shell selects the heading that is the tab', (tester) async {
      final shell = await pumpShell(tester, at: '/library/authors');
      final nav = AdaptiveNav(
        menu: [
          entry('Home', route: const HomeRoute(), tab: 0),
          entry(
            'Library',
            tab: 3,
            children: [entry('Books', route: const BooksRoute())],
          ),
        ],
        width: 400,
        shell: shell,
      );
      expect(shell.currentIndex, 3);
      expect(nav.selectedIndex, 1);
    });

    testWidgets('a shell and no entry for the current tab selects nothing', (
      tester,
    ) async {
      final shell = await pumpShell(tester, at: '/library/books');
      final nav = AdaptiveNav(
        menu: [
          entry('Home', route: const HomeRoute(), tab: 0),
          entry('Search', route: const SearchRoute(), tab: 1),
        ],
        width: 400,
        shell: shell,
      );
      expect(nav.selectedIndex, isNull);
      expect(nav.visible, isFalse);
    });

    testWidgets(
      'a shell and no tabs in the menu (no under:) goes by the page',
      (tester) async {
        final shell = await pumpShell(tester, at: '/search');
        final nav = AdaptiveNav(
          menu: [
            entry('Home', route: const HomeRoute()),
            entry('Search', route: const SearchRoute(), selected: true),
            entry('Profile', route: const ProfileRoute()),
          ],
          width: 400,
          shell: shell,
        );
        expect(nav.selectedIndex, 1);
        expect(nav.visible, isTrue);
      },
    );

    test('a plain layout selects the first selected entry', () {
      final menu = [
        entry('Home', route: const HomeRoute()),
        entry('Search', route: const SearchRoute(), selected: true),
        entry('Profile', route: const ProfileRoute(), selected: true),
      ];
      expect(AdaptiveNav(menu: menu, width: 400).selectedIndex, 1);
      expect(AdaptiveNav(menu: menu, width: 700).selectedIndex, 1);
    });

    test('a page that is under no entry selects nothing', () {
      final nav = AdaptiveNav(
        menu: [
          entry('Home', route: const HomeRoute()),
          entry('Search', route: const SearchRoute()),
        ],
        width: 400,
      );
      expect(nav.selectedIndex, isNull);
    });
  });

  group('visible and enabled', () {
    final two = [
      entry('Home', route: const HomeRoute(), selected: true),
      entry('Search', route: const SearchRoute()),
    ];

    test('two destinations or more are shown', () {
      for (final width in [400.0, 700.0, 1300.0]) {
        expect(AdaptiveNav(menu: two, width: width).visible, isTrue);
      }
    });

    test('fewer than two are not, in any mode', () {
      for (final width in [400.0, 700.0, 1300.0]) {
        expect(
          AdaptiveNav(menu: [two.first], width: width).visible,
          isFalse,
          reason: 'width $width',
        );
        expect(
          AdaptiveNav(menu: const [], width: width).visible,
          isFalse,
          reason: 'width $width',
        );
      }
    });

    test(
      'a bar with nothing selected is not shown, a rail and a drawer are',
      () {
        final none = [
          entry('Home', route: const HomeRoute()),
          entry('Search', route: const SearchRoute()),
        ];
        expect(AdaptiveNav(menu: none, width: 400).visible, isFalse);
        expect(AdaptiveNav(menu: none, width: 700).visible, isTrue);
        expect(AdaptiveNav(menu: none, width: 700).selectedIndex, isNull);
        expect(AdaptiveNav(menu: none, width: 1300).visible, isTrue);
      },
    );

    testWidgets(
      'a refused entry that is listed is not enabled; pending and tabs are',
      (tester) async {
        final shell = await pumpShell(tester);
        final nav = AdaptiveNav(
          menu: [
            entry('Home', route: const HomeRoute(), tab: 0),
            entry(
              'Search',
              route: const SearchRoute(),
              tab: 1,
              access: NavAccess.refused,
            ),
            entry(
              'Profile',
              route: const ProfileRoute(),
              tab: 2,
              access: NavAccess.pending,
            ),
            // A heading is not `enabled` as an entry (it has no route), but it is a tab, and
            // nothing refuses it.
            entry('Library', tab: 3),
          ],
          width: 400,
          shell: shell,
        );
        expect(labels(nav.destinations), [
          'Home',
          'Search',
          'Profile',
          'Library',
        ]);
        expect(
          [for (var i = 0; i < 4; i++) nav.enabled(i)],
          [true, false, true, true],
        );
        expect(nav.destinations[3].enabled, isFalse);
      },
    );
  });

  test('the mode and the width are the ones the breakpoints give', () {
    const menu = <NavItem>[];
    expect(AdaptiveNav(menu: menu, width: 599).mode, NavMode.bar);
    expect(AdaptiveNav(menu: menu, width: 600).mode, NavMode.rail);
    expect(AdaptiveNav(menu: menu, width: 1200).mode, NavMode.drawer);
    expect(AdaptiveNav(menu: menu, width: 1200).width, 1200);
    expect(
      AdaptiveNav(
        menu: menu,
        width: 1200,
        breakpoints: NavBreakpoints.noDrawer,
      ).mode,
      NavMode.rail,
    );
    expect(
      AdaptiveNav(
        menu: menu,
        width: 700,
        breakpoints: const NavBreakpoints(rail: 840),
      ).mode,
      NavMode.bar,
    );
  });

  group('select', () {
    final menu = [
      entry('Home', route: const HomeRoute(), tab: 0),
      entry('Search', route: const SearchRoute(), tab: 1),
      entry('Profile', route: const ProfileRoute(), tab: 2),
      entry(
        'Library',
        tab: 3,
        children: [
          entry('Books', route: const BooksRoute()),
          entry('Authors', route: const AuthorsRoute()),
        ],
      ),
    ];

    testWidgets('the current tab again goes back to its first page', (
      tester,
    ) async {
      final shell = await pumpShell(tester, at: '/library/authors');
      expect(currentLocation(tester), '/library/authors');
      final nav = AdaptiveNav(menu: menu, width: 400, shell: shell);
      expect(nav.destinations[3].nav.label, 'Library');

      nav.select(lastContext!, 3);
      await tester.pumpAndSettle();
      // goBranch(3, initialLocation: true): the branch's first route.
      expect(currentLocation(tester), '/library/books');
    });

    testWidgets('another tab is shown as it was left', (tester) async {
      final shell = await pumpShell(tester, at: '/library/authors');
      final nav = AdaptiveNav(menu: menu, width: 400, shell: shell);

      nav.select(lastContext!, 0);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/');
      expect(lastShell!.currentIndex, 0);

      // goBranch(3): Library keeps the page it was on.
      AdaptiveNav(
        menu: menu,
        width: 400,
        shell: lastShell,
      ).select(lastContext!, 3);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/library/authors');
    });

    testWidgets('an entry with no tab goes to its route', (tester) async {
      final shell = await pumpShell(tester);
      // The drawer lists Books and Authors, which are not tabs of this layout.
      final nav = AdaptiveNav(menu: menu, width: 1300, shell: shell);
      expect(labels(nav.destinations), [
        'Home',
        'Search',
        'Profile',
        'Books',
        'Authors',
      ]);
      nav.select(lastContext!, 4);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/library/authors');
      expect(lastShell!.currentIndex, 3);
    });

    testWidgets('a plain layout goes to the route', (tester) async {
      await pumpShell(tester);
      final nav = AdaptiveNav(
        menu: [
          entry('Home', route: const HomeRoute()),
          entry('Search', route: const SearchRoute()),
        ],
        width: 400,
      );
      nav.select(lastContext!, 1);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/search');
    });
  });
}
