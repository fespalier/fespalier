/// `nav.dart` menus as a navigation bar, a rail or a permanent drawer by window width (since
/// 0.9.0): the model, with no Material import.
///
/// [AdaptiveNav] turns the entries `AppMenu.watch(ref, under: ...)` gives into the destinations one
/// component lists at one width, [NavBreakpoints] says where the bar gives way to the rail and the
/// rail to the drawer, and [AdaptiveNavBuilder] hands the model to a builder of yours. The widgets
/// that draw it with Material are in `package:fespalier_adaptive/material.dart`.
///
/// ```dart
/// AdaptiveNavBuilder(
///   menu: (ref) => AppMenu.watch(ref, under: '(tabs)'),
///   shell: navigationShell,
///   builder: (context, nav) => MyNavigation(nav: nav, body: navigationShell),
/// )
/// ```
library;

export 'src/adaptive_nav.dart' show AdaptiveNav, NavSection;
export 'src/breakpoints.dart' show NavBreakpoints, NavMode, WindowSizeClass;
export 'src/builder.dart' show AdaptiveNavBuilder;
