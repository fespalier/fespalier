/// The custom keys this sink sets on a Crashlytics report (since 0.18.0).
///
/// Firebase names a custom key with letters, digits and underscores, so these are the telemetry
/// conventions' names with `_` in place of `.`: `fespalier.operation` is `fespalier_operation`. There
/// are five, well under Crashlytics' limit of 64 keys, and each is set on every report: `''` when
/// there is no value for it.
abstract final class CrashlyticsKeys {
  /// The pattern of the screen the person is on (`/products/:id`), set at each committed navigation
  /// and sent only when it changes; `''` when the location matched no route. A crash that the app's
  /// own handlers record carries it, so it says where the app was.
  static const String screen = 'fespalier_screen';

  /// The route pattern of the operation that failed (`/products/:id`), or `''`.
  static const String route = 'fespalier_route';

  /// The app file that failed (`products/$id/data.dart`), or `''`.
  static const String file = 'fespalier_file';

  /// The kind of operation that failed (`guard`, `redirect`, `data`, `action`, `deferred`, or
  /// `custom` when the app's `capture` says so), or `''`.
  static const String operation = 'fespalier_operation';

  /// The function name of the action that failed (`rename`), or `''`.
  static const String action = 'fespalier_action';
}
