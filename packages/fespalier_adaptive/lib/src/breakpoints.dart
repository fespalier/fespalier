/// Material 3's window size classes (since 0.9.0), by the window's width in logical pixels.
enum WindowSizeClass {
  /// Under 600: phones in portrait.
  compact,

  /// 600 to 839: tablets in portrait, foldables.
  medium,

  /// 840 to 1199.
  expanded,

  /// 1200 to 1599.
  large,

  /// 1600 and wider.
  extraLarge;

  /// The class of a window [width] wide.
  static WindowSizeClass of(double width) {
    if (width < 600) return compact;
    if (width < 840) return medium;
    if (width < 1200) return expanded;
    if (width < 1600) return large;
    return extraLarge;
  }
}

/// How the menu is shown (since 0.9.0).
enum NavMode {
  /// A `NavigationBar` at the bottom.
  bar,

  /// A `NavigationRail` at the start.
  rail,

  /// A `NavigationDrawer` at the start, always open, with the nested entries.
  drawer,
}

/// The widths at which the rail and the drawer take over (since 0.9.0).
///
/// ```dart
/// const NavBreakpoints(); // a bar under 600, a rail from 600, a drawer from 1200
/// const NavBreakpoints(rail: 840); // a bar up to small tablets in portrait
/// NavBreakpoints.noDrawer; // a bar, then a rail, never a drawer
/// ```
final class NavBreakpoints {
  /// The rail from [rail] logical pixels, the drawer from [drawer]; null: never.
  const NavBreakpoints({this.rail = 600, this.drawer = 1200})
    : assert(
        rail == null || drawer == null || drawer >= rail,
        'NavBreakpoints: drawer is below rail',
      );

  /// Material 3's: a bar when compact, a rail from medium, a drawer from large.
  static const NavBreakpoints material = NavBreakpoints();

  /// A bar, then a rail from 600, and never a drawer.
  static const NavBreakpoints noDrawer = NavBreakpoints(drawer: null);

  /// Where the rail starts; null: never.
  final double? rail;

  /// Where the drawer starts; null: never.
  final double? drawer;

  /// The mode for a window [width] wide: the drawer from [drawer], else the rail from [rail], else
  /// the bar.
  NavMode modeFor(double width) {
    final drawer = this.drawer;
    if (drawer != null && width >= drawer) return NavMode.drawer;
    final rail = this.rail;
    if (rail != null && width >= rail) return NavMode.rail;
    return NavMode.bar;
  }
}
