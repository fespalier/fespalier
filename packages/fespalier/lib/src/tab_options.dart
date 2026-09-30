/// Options for one tab of a tab layout, set in the layout's `tabOptions`:
///
/// ```dart
/// const tabOptions = {
///   'search': TabOptions(preload: true),
///   'profile': TabOptions(initialLocation: '/profile/edit'),
/// };
/// ```
///
/// `fsp gen` reads the map from the source, so it must be a `const` map
/// literal with string keys (the tab names, as in `tabs`) and constructor
/// calls with literal arguments. Nothing reads it at runtime.
class TabOptions {
  const TabOptions({this.preload = false, this.initialLocation});

  /// Build the tab as soon as the layout first shows, instead of on its first
  /// visit (go_router's `StatefulShellBranch.preload`).
  final bool preload;

  /// Where the tab opens the first time, and when its tab is tapped with
  /// `goBranch(i, initialLocation: true)`, instead of its first route. An app
  /// location such as `/profile/edit`, which must be a route inside the tab
  /// (go_router's `StatefulShellBranch.initialLocation`; `fsp gen` prefixes
  /// the mount point).
  final String? initialLocation;
}
