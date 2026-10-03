import 'package:fespalier/fespalier.dart';
import 'package:fespalier_adaptive/material.dart';
import 'package:flutter/material.dart';
import 'package:tabs/app.g.dart';
import 'package:tabs/cross_fade.dart';

/// Asking for a `StatefulNavigationShell` instead of a `child` makes this a
/// tab layout: each branch keeps its own navigation stack and state.
///
/// Without `tabs`, the branches would follow folder order (`(home)`, `library`,
/// `profile`, `search`).
const tabs = ['(home)', 'search', 'profile', 'library'];

/// Per-tab options, read by `fsp gen` into the `StatefulShellBranch`es: Search
/// is built up front, and the Library tab opens on its Authors tab. (Library
/// has a tab layout of its own: tab layouts nest.)
const tabOptions = {
  'search': TabOptions(preload: true),
  'library': TabOptions(initialLocation: '/library/authors'),
};

/// Optional: how the tabs' navigators are put together. With it, the layout is a
/// `StatefulShellRoute(navigatorContainerBuilder: container)`; without it, an
/// `indexedStack`. The parameters are positional with these types (the names
/// are yours). Here the tabs cross-fade, and each keeps its state.
Widget container(
  BuildContext context,
  StatefulNavigationShell shell,
  List<Widget> children,
) =>
    CrossFadeContainer(currentIndex: shell.currentIndex, children: children);

/// The bar is the menu: `nav.dart` in each tab's folder says what it is called and what its icon
/// is, and `AdaptiveNavScaffold` shows `AppMenu.watch` as a `NavigationBar` on a phone, a
/// `NavigationRail` on a tablet and a `NavigationDrawer` on a wide window, around the same
/// `navigationShell`, so a tab keeps its state when the window changes size.
///
/// `rail: 840`: a bar up to small tablets in portrait (the default is 600), and Flutter's default
/// 800 x 600 test window keeps the bar. The drawer starts at 1200.
class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => AdaptiveNavScaffold(
        shell: navigationShell,
        // `under:` the tab layout's folder, so each entry knows its tab: tapping the current one
        // goes back to its first page, and the Library heading is a tab.
        menu: (ref) => AppMenu.watch(ref, under: '(tabs)'),
        breakpoints: const NavBreakpoints(rail: 840),
      );
}
