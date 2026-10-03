import 'package:fespalier/fespalier.dart' show StatefulNavigationShell;
import 'package:fespalier/nav.dart' show NavAccess, NavItem;
import 'package:flutter/widgets.dart';

import 'breakpoints.dart';

/// A drawer section: a heading (an entry without a route) and the destinations below it, by index
/// (since 0.9.0).
final class NavSection {
  /// The section [heading] (null: the top level) over destinations [start] to [end] (exclusive).
  const NavSection(this.heading, this.start, this.end);

  /// The heading entry; null for the entries at the top level.
  final NavItem? heading;

  /// The first destination of the section.
  final int start;

  /// One past its last destination.
  final int end;
}

/// The menu as one navigation component shows it at one width (since 0.9.0): what
/// `AdaptiveNavScaffold` renders, and what an `AdaptiveNavBuilder` gets to render it another way.
///
/// It is plain data and a function, made from the entries `AppMenu.watch(ref, under: ...)` gives:
///
/// - The bar and the rail list the top-level entries that go somewhere: an entry with a route,
///   or, with a `shell`, an entry with a `tab`, even a heading (the Library tab of `examples/tabs`
///   has no page of its own). A heading that goes nowhere is replaced by its children.
/// - The drawer lists every entry that goes somewhere, depth first, with a heading as a section
///   title over the entries below it.
/// - A destination is selected by its `tab` (with a `shell`), else by the page: the first selected
///   entry for a bar or a rail, the deepest one for the drawer.
final class AdaptiveNav {
  AdaptiveNav._({
    required this.mode,
    required this.width,
    required this.destinations,
    required this.sections,
    required this.selectedIndex,
    required StatefulNavigationShell? shell,
  }) : _shell = shell;

  /// The model of [menu] (`AppMenu.watch(ref, under: ...)`) for a window [width] wide. With [shell],
  /// entries with a `tab` switch tabs.
  factory AdaptiveNav({
    required List<NavItem> menu,
    required double width,
    StatefulNavigationShell? shell,
    NavBreakpoints breakpoints = NavBreakpoints.material,
  }) {
    final mode = breakpoints.modeFor(width);
    final destinations = <NavItem>[];
    final sections = <NavSection>[];
    if (mode == NavMode.drawer) {
      _tree(menu, shell != null, destinations, sections);
    } else {
      _flat(menu, shell != null, destinations);
      sections.add(NavSection(null, 0, destinations.length));
    }
    return AdaptiveNav._(
      mode: mode,
      width: width,
      destinations: destinations,
      sections: sections,
      selectedIndex: _selected(mode, destinations, shell),
      shell: shell,
    );
  }

  final StatefulNavigationShell? _shell;

  /// Bar, rail or drawer.
  final NavMode mode;

  /// The window's width it was made for.
  final double width;

  /// The entries the component lists, in order.
  final List<NavItem> destinations;

  /// For [NavMode.drawer]: [destinations] by section, in order; one top-level section otherwise.
  final List<NavSection> sections;

  /// The destination that is the current page or tab; null when none is.
  final int? selectedIndex;

  /// Whether a component is shown at all: two destinations or more, and for a bar a selected one
  /// (a `NavigationBar` cannot show "nothing selected": it asserts a selected index).
  bool get visible =>
      destinations.length >= 2 &&
      (mode != NavMode.bar || selectedIndex != null);

  /// Whether destination [index] can be tapped: its guards do not refuse it now.
  ///
  /// A destination whose guards have not answered yet is enabled, and so is a heading that is a tab.
  bool enabled(int index) => destinations[index].access != NavAccess.refused;

  /// Goes to destination [index]: `goBranch` for a tab (its first page when it is the current one),
  /// else the entry's route.
  void select(BuildContext context, int index) {
    final item = destinations[index];
    final shell = _shell;
    final tab = item.tab;
    if (shell != null && tab != null) {
      shell.goBranch(tab, initialLocation: tab == shell.currentIndex);
    } else {
      item.go(context);
    }
  }
}

/// Whether [item] is a destination of its own: it has a route, or it is a tab of the [shell]'s layout.
bool _goesSomewhere(NavItem item, bool tabs) =>
    item.route != null || (tabs && item.tab != null);

/// The destinations of a bar or a rail: the top-level entries that go somewhere. An entry that goes
/// nowhere (a heading) is replaced by the entries below it.
void _flat(List<NavItem> items, bool tabs, List<NavItem> out) {
  for (final item in items) {
    if (_goesSomewhere(item, tabs)) {
      out.add(item);
    } else {
      _flat(item.children, tabs, out);
    }
  }
}

/// The destinations of the drawer, depth first, and the sections they fall in.
void _tree(
  List<NavItem> menu,
  bool tabs,
  List<NavItem> destinations,
  List<NavSection> sections,
) {
  // Each destination with the heading it sits under. A route's children stay in its section, so a
  // tree of three levels or more is flattened under one heading level.
  final placed = <(NavItem?, NavItem)>[];
  void walk(List<NavItem> items, NavItem? heading) {
    for (final item in items) {
      if (item.route != null) {
        placed.add((heading, item));
        walk(item.children, heading);
      } else if (tabs && item.tab != null && item.children.isEmpty) {
        placed.add((heading, item));
      } else {
        walk(item.children, item);
      }
    }
  }

  walk(menu, null);
  var start = 0;
  for (var i = 1; i <= placed.length; i++) {
    if (i == placed.length || !identical(placed[i].$1, placed[start].$1)) {
      sections.add(NavSection(placed[start].$1, start, i));
      start = i;
    }
  }
  destinations.addAll(placed.map((p) => p.$2));
}

/// The index of the destination that is the current tab or page, or null.
int? _selected(
  NavMode mode,
  List<NavItem> destinations,
  StatefulNavigationShell? shell,
) {
  if (mode == NavMode.drawer) {
    // Depth first puts a route before the entries below it: the last selected one is the deepest.
    final deepest = destinations.lastIndexWhere(
      (d) => d.selected && d.route != null,
    );
    if (deepest >= 0) return deepest;
    return _tab(destinations, shell);
  }
  // Entries go by tab when the menu knows the tabs (`AppMenu.watch(ref, under: ...)`); without
  // `under:` no entry has a tab, and they go by the page.
  if (shell != null && destinations.any((d) => d.tab != null)) {
    return _tab(destinations, shell);
  }
  final page = destinations.indexWhere((d) => d.selected);
  return page < 0 ? null : page;
}

int? _tab(List<NavItem> destinations, StatefulNavigationShell? shell) {
  if (shell == null) return null;
  final i = destinations.indexWhere((d) => d.tab == shell.currentIndex);
  return i < 0 ? null : i;
}
