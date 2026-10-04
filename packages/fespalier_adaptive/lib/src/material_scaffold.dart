import 'package:fespalier/fespalier.dart'
    show StatefulNavigationShell, WidgetRef;
import 'package:fespalier/nav.dart' show NavItem;
import 'package:flutter/material.dart';

import 'adaptive_nav.dart';
import 'breakpoints.dart';
import 'builder.dart';
import 'messages.dart';

/// A destination's icon: `Nav.selectedIcon` while selected, else `Nav.icon` (since 0.9.0).
///
/// An entry with no icon gets an empty box of icon size: Material's destinations need an icon
/// widget.
Widget defaultNavIcon(BuildContext context, NavItem item, bool selected) =>
    Icon(selected ? (item.nav.selectedIcon ?? item.nav.icon) : item.nav.icon);

/// Where the body sits, in every mode: the same place of the tree, so a tab's state survives the
/// window changing size.
const _bodyKey = ValueKey<String>('fespalier_adaptive.body');

/// The menu `nav.dart` files describe as a `NavigationBar`, a `NavigationRail` or a
/// `NavigationDrawer`, by the window's width, around a layout's body (since 0.9.0).
///
/// ```dart
/// // lib/app/(tabs)/layout.dart
/// class TabsLayout extends StatelessWidget {
///   const TabsLayout({super.key, required this.navigationShell});
///   final StatefulNavigationShell navigationShell;
///
///   @override
///   Widget build(BuildContext context) => AdaptiveNavScaffold(
///     shell: navigationShell,
///     menu: (ref) => AppMenu.watch(ref, under: '(tabs)'),
///   );
/// }
/// ```
///
/// - Under the rail breakpoint (600 by default) a bar sits at the bottom, from it a rail at the
///   start, from the drawer breakpoint (1200) a permanent drawer with the nested entries.
/// - The body is the [shell] (a tab layout: each tab keeps its stack and state) or the [child] (a
///   plain layout). It sits at one place in the tree in every mode.
/// - **The bar is hidden on a page that no menu entry covers**: a `NavigationBar` cannot show
///   "nothing selected". A rail and a drawer show none selected. Give the page's folder a
///   `nav.dart`, or put it below an entry, or render the menu with an `AdaptiveNavBuilder`.
/// - Guards decide what is listed, as they do for any menu: a refused entry is absent, or
///   disabled with `NavRefused.disable`.
class AdaptiveNavScaffold extends StatelessWidget {
  /// A scaffold around [shell] (a tab layout) or [child] (a plain layout): exactly one of them.
  const AdaptiveNavScaffold({
    super.key,
    required this.menu,
    this.shell,
    this.child,
    this.breakpoints = NavBreakpoints.material,
    this.icon = defaultNavIcon,
    this.leading,
    this.trailing,
    this.floatingActionButton,
  }) : assert(
         (shell == null) != (child == null),
         'AdaptiveNavScaffold takes shell: (a tab layout) or child: (a plain layout), exactly one of them.',
       );

  /// The entries: `(ref) => AppMenu.watch(ref, under: '(tabs)')`. Pass `under:` the tab layout's
  /// folder for a tab layout, so each entry knows its tab.
  final List<NavItem> Function(WidgetRef ref) menu;

  /// The tab layout's shell, for a tab layout.
  final StatefulNavigationShell? shell;

  /// The layout's child, for a plain layout.
  final Widget? child;

  /// Where the rail and the drawer take over.
  final NavBreakpoints breakpoints;

  /// A destination's icon: wrap it in a `Badge` here.
  final Widget Function(BuildContext context, NavItem item, bool selected) icon;

  /// Above the rail's or the drawer's destinations (a FAB, a logo); not shown with the bar.
  final Widget Function(BuildContext context, AdaptiveNav nav)? leading;

  /// Below them.
  final Widget Function(BuildContext context, AdaptiveNav nav)? trailing;

  /// The `Scaffold`'s floating action button: called in every mode, so return null where the button
  /// went into [leading].
  final Widget? Function(BuildContext context, AdaptiveNav nav)?
  floatingActionButton;

  @override
  Widget build(BuildContext context) => AdaptiveNavBuilder(
    menu: menu,
    shell: shell,
    breakpoints: breakpoints,
    builder: _scaffold,
  );

  Widget _scaffold(BuildContext context, AdaptiveNav nav) {
    final shell = this.shell;
    if (shell != null && nav.mode == NavMode.bar && nav.selectedIndex == null) {
      debugReportNoTabEntry(shell.currentIndex);
    }
    // Nothing at all when the component would be empty or, for a bar, select nothing.
    final mode = nav.visible ? nav.mode : null;
    return Scaffold(
      floatingActionButton: floatingActionButton?.call(context, nav),
      body: Row(
        children: [
          ?switch (mode) {
            NavMode.rail => _rail(context, nav),
            NavMode.drawer => _drawer(context, nav),
            _ => null,
          },
          Expanded(key: _bodyKey, child: (shell ?? child)!),
        ],
      ),
      bottomNavigationBar: mode == NavMode.bar ? _bar(context, nav) : null,
    );
  }

  Widget _bar(BuildContext context, AdaptiveNav nav) => NavigationBar(
    // `visible` is true: a bar is shown only with a selected destination.
    selectedIndex: nav.selectedIndex!,
    onDestinationSelected: (i) => nav.select(context, i),
    destinations: [
      for (final (i, item) in nav.destinations.indexed)
        NavigationDestination(
          icon: icon(context, item, false),
          selectedIcon: icon(context, item, true),
          label: item.label(context),
          enabled: nav.enabled(i),
        ),
    ],
  );

  Widget _rail(BuildContext context, AdaptiveNav nav) => NavigationRail(
    selectedIndex: nav.selectedIndex,
    onDestinationSelected: (i) => nav.select(context, i),
    labelType: NavigationRailLabelType.all,
    leading: leading?.call(context, nav),
    trailing: trailing?.call(context, nav),
    destinations: [
      for (final (i, item) in nav.destinations.indexed)
        NavigationRailDestination(
          icon: icon(context, item, false),
          selectedIcon: icon(context, item, true),
          label: Text(item.label(context)),
          disabled: !nav.enabled(i),
        ),
    ],
  );

  Widget _drawer(BuildContext context, AdaptiveNav nav) {
    final title = Theme.of(context).textTheme.titleSmall;
    final leading = this.leading?.call(context, nav);
    final trailing = this.trailing?.call(context, nav);
    return DrawerTheme(
      // Material 3's standard (permanent) drawer: square and flat, as it is beside the body.
      data: DrawerTheme.of(
        context,
      ).copyWith(shape: const RoundedRectangleBorder()),
      child: NavigationDrawer(
        elevation: 0,
        selectedIndex: nav.selectedIndex,
        onDestinationSelected: (i) => nav.select(context, i),
        children: [
          ?leading,
          for (final (n, section) in nav.sections.indexed) ...[
            if (n > 0)
              const Padding(
                padding: EdgeInsetsDirectional.fromSTEB(28, 8, 28, 8),
                child: Divider(),
              ),
            if (section.heading case final heading?)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(28, 16, 16, 10),
                child: Text(heading.label(context), style: title),
              ),
            for (var i = section.start; i < section.end; i++)
              NavigationDrawerDestination(
                icon: icon(context, nav.destinations[i], false),
                selectedIcon: icon(context, nav.destinations[i], true),
                label: Text(nav.destinations[i].label(context)),
                enabled: nav.enabled(i),
              ),
          ],
          ?trailing,
        ],
      ),
    );
  }
}
