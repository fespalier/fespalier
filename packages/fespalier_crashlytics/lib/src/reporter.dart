/// The port the sink reports through (since 0.18.0): one non-fatal report, the session's custom keys
/// and a log line. Any crash reporter with this shape can implement it (Firebase Crashlytics, Bugsnag,
/// Datadog); this package depends on none of them.
///
/// The sink calls each method synchronously, from the router, a provider or an action, so a method
/// must return at once: return the vendor's `Future`, or null, and never await it. The sink drops the
/// result of a returned `Future` and its failure, and a method that throws costs that one call, never
/// the app. Nothing a method is given carries a URL, a segment or query value, an id, a payload, user
/// text or an error's message: only class names, route patterns, app file paths and constants.
abstract class CrashReporter {
  /// Constant so a reporter with no state can be `const`.
  const CrashReporter();

  /// A non-fatal report of [error], with its [stack]. [reason] is the line a console shows with the
  /// report, and [keys] belong to this report: a reporter whose keys are the session's (Crashlytics)
  /// sets each of them before it records, so the report carries them.
  Future<void>? recordError(
    Object error,
    StackTrace? stack, {
    required String reason,
    required Map<String, String> keys,
  });

  /// Sets the session's custom key [key] to [value]. An empty value is a value: the key stays set.
  Future<void>? setCustomKey(String key, String value);

  /// A line in the log that a report carries.
  Future<void>? log(String message);
}
