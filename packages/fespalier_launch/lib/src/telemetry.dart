/// The names fespalier_launch reports (since 0.18.0). The package's own contract, pinned by
/// `test/telemetry_test.dart`: add a key, never rename one. A shortcut type, a widget URI, a path,
/// a query, an id and the vendor's text are never reported: only the constants below.
abstract final class FespalierLaunchConventions {
  /// An action was handled: a span from the action to the navigation call (or to the decision
  /// that there is none).
  static const String open = 'fespalier.launch.open';

  /// Start attribute of [open]: [cold] or [warm].
  static const String state = 'fespalier.launch.state';

  /// Start attribute of [open]: the `NavigationSource` value of the action, `shortcut` or
  /// `widget`. The navigation it starts carries the same value as `fespalier.navigation.source`.
  static const String kind = 'fespalier.launch.kind';

  /// End attribute of [open]: whether the mapping gave a place and the navigation was made
  /// (`bool`). On a cold start another adapter's `launch()` may still win: then the place was
  /// given and not used.
  static const String routed = 'fespalier.launch.routed';

  /// [state] value: the action that cold-started the app.
  static const String cold = 'cold';

  /// [state] value: an action while the app ran or sat in the background.
  static const String warm = 'warm';
}
