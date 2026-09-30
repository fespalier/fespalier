import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
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

class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (i) => navigationShell.goBranch(
            i,
            // Tapping the current tab goes back to its first page.
            initialLocation: i == navigationShell.currentIndex,
          ),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
            NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
            NavigationDestination(icon: Icon(Icons.library_books), label: 'Library'),
          ],
        ),
      );
}
