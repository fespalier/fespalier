/// The navigator a folder's routes render on, set in its `navigator.dart`:
///
/// ```dart
/// // lib/app/(tabs)/orders/$id/navigator.dart
/// const navigator = RouteNavigator.root;
/// ```
///
/// A route's URL and the navigator it renders on are separate decisions. `root`
/// keeps the URL inside a tab (so a deep link, the back stack and the tab's state
/// are right) but shows the page above the whole tab layout, over its navigation
/// bar. It applies to the folder's routes and to every folder below it, and the
/// nearest declaration wins.
///
/// `fsp gen` reads the file from the source, so it must be a `const` variable
/// called `navigator` holding one of these values, spelled out. Nothing reads it
/// at runtime.
enum RouteNavigator {
  /// The generated router's root navigator (`AppRoutes.rootNavigatorKey`): above
  /// every layout and tab bar.
  root,

  /// The enclosing shell's own navigator, inside its layout: what a route
  /// does without a `navigator.dart`. It is for a folder below a `layout.dart`
  /// that sits below a `root` folder; go_router doesn't let a route go back to a
  /// shell that is above a root-navigator route.
  shell,
}
