/// The names fespalier_push reports (since 0.13.0). The package's own contract, pinned by
/// `test/telemetry_test.dart`: add a key, never rename one. A payload, a title, a body, a
/// message id and a token are never reported.
abstract final class FespalierPushConventions {
  /// A tap was handled: a span from the tap to the navigation call.
  static const String open = 'fespalier.push.open';

  /// Start attribute of [open]: [cold] or [warm].
  static const String state = 'fespalier.push.state';

  /// End attribute of [open]: whether the mapping gave a place (`bool`).
  static const String routed = 'fespalier.push.routed';

  /// [state] value: the tap that cold-started the app.
  static const String cold = 'cold';

  /// [state] value: a tap while the app ran or sat in the background.
  static const String warm = 'warm';
}
