import 'package:fespalier/fespalier.dart'
    show ConsumerWidget, StatefulNavigationShell, WidgetRef;
import 'package:fespalier/nav.dart' show NavItem;
import 'package:flutter/widgets.dart';

import 'adaptive_nav.dart';
import 'breakpoints.dart';

/// Builds [builder] with the [AdaptiveNav] of [menu] at the window's width (since 0.9.0): the way to
/// render the menu with widgets of your own (Cupertino, `material_ui`, chips).
///
/// ```dart
/// // lib/app/(tabs)/library/layout.dart: the tabs of a nested tab layout as chips
/// class LibraryLayout extends StatelessWidget {
///   const LibraryLayout({super.key, required this.navigationShell});
///   final StatefulNavigationShell navigationShell;
///
///   @override
///   Widget build(BuildContext context) => AdaptiveNavBuilder(
///     menu: (ref) => AppMenu.watch(ref, under: '(tabs)/library'),
///     shell: navigationShell,
///     builder: (context, nav) => Column(
///       children: [
///         Row(
///           children: [
///             for (final (i, item) in nav.destinations.indexed)
///               ChoiceChip(
///                 label: Text(item.label(context)),
///                 selected: nav.selectedIndex == i,
///                 onSelected: (_) => nav.select(context, i),
///               ),
///           ],
///         ),
///         Expanded(child: navigationShell),
///       ],
///     ),
///   );
/// }
/// ```
///
/// Put the body (the shell or the child) at the same place of the tree in every mode, or the
/// state of a tab is lost when the window changes size: a layout that returns a different widget
/// type around it for a bar and for a rail rebuilds the page.
///
/// The width is the window's (`MediaQuery.sizeOf(context).width`). A layout in a split view that
/// needs the width of its own box builds an [AdaptiveNav] itself, with a `LayoutBuilder`.
class AdaptiveNavBuilder extends ConsumerWidget {
  /// Watches [menu] and rebuilds with the width.
  const AdaptiveNavBuilder({
    super.key,
    required this.menu,
    this.shell,
    this.breakpoints = NavBreakpoints.material,
    required this.builder,
  });

  /// The entries: `(ref) => AppMenu.watch(ref, under: '(tabs)')`. It is called in `build`, so the
  /// guards of the entries are watched while this widget is on screen.
  final List<NavItem> Function(WidgetRef ref) menu;

  /// The tab layout's shell, for a tab layout; null in a plain layout.
  final StatefulNavigationShell? shell;

  /// Where the rail and the drawer take over.
  final NavBreakpoints breakpoints;

  /// Builds the layout from the model.
  final Widget Function(BuildContext context, AdaptiveNav nav) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => builder(
    context,
    AdaptiveNav(
      menu: menu(ref),
      width: MediaQuery.sizeOf(context).width,
      shell: shell,
      breakpoints: breakpoints,
    ),
  );
}
