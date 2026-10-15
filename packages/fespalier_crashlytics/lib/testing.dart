/// Test doubles for `fespalier_crashlytics` (since 0.18.0): a [CrashReporter] that keeps what it is
/// given, so a test reads the reasons, the keys and the log lines the sink sent, with no Firebase,
/// no platform channel and no network.
///
/// ```dart
/// final crash = RecordingCrashlytics();
/// FespalierTelemetry.install(FespalierCrashlytics(crash));
/// // ... navigate, pump ...
/// expect(crash.lines, [r'error StateError in data items/$id/data.dart on /items/:id']);
/// ```
library;

import 'src/reporter.dart';

/// A [CrashReporter] that keeps every call (since 0.18.0). It is the reporter a test gives the sink,
/// in place of the Firebase one.
///
/// Its session [keys] are what Crashlytics would keep: each `setCustomKey` sets one, and a report's
/// keys are merged in before it is kept. [lines] is one line per call, in order, and [strings] is
/// everything the sink sent as text (for a test that asserts nothing private got through).
final class RecordingCrashlytics extends CrashReporter {
  /// With [throwing], every call records and then throws a [StateError], as a broken SDK would. With
  /// [failing], every call records and then returns a `Future` that fails with a [StateError].
  RecordingCrashlytics({this.throwing = false, this.failing = false});

  /// Whether every call throws after it records.
  final bool throwing;

  /// Whether every call returns a failed `Future` after it records.
  final bool failing;

  /// The reports, in order.
  final List<RecordedError> errors = [];

  /// The session's custom keys, as Crashlytics keeps them. A report's own keys are merged in when it
  /// is recorded, so after a report this holds its keys too.
  final Map<String, String> keys = {};

  /// The log lines, in order.
  final List<String> logs = [];

  /// One line per call, in order: `key <name>=<value>` for a custom key, `log <message>` for a log
  /// line, and `error <ExceptionType> <reason>` for a report. A report's own keys are not lines.
  final List<String> lines = [];

  /// Every key value ever set, the session's and each report's, in order.
  final List<String> _keyValues = [];

  /// Everything the reporter was given as text: every reason, every key value ever set (the session's
  /// and each report's) and every log line. Never an error object: that one is the app's.
  Iterable<String> get strings => [
    for (final e in errors) e.reason,
    ..._keyValues,
    ...logs,
  ];

  @override
  Future<void>? recordError(
    Object error,
    StackTrace? stack, {
    required String reason,
    required Map<String, String> keys,
  }) {
    for (final entry in keys.entries) {
      this.keys[entry.key] = entry.value;
      _keyValues.add(entry.value);
    }
    errors.add(
      RecordedError(
        error,
        stack,
        reason,
        Map<String, String>.unmodifiable(Map<String, String>.of(this.keys)),
      ),
    );
    lines.add('error ${error.runtimeType} $reason');
    return _outcome('recordError');
  }

  @override
  Future<void>? setCustomKey(String key, String value) {
    keys[key] = value;
    _keyValues.add(value);
    lines.add('key $key=$value');
    return _outcome('setCustomKey');
  }

  @override
  Future<void>? log(String message) {
    logs.add(message);
    lines.add('log $message');
    return _outcome('log');
  }

  /// What a call returns after it recorded: nothing, a failed `Future`, or a throw.
  Future<void>? _outcome(String call) {
    if (throwing) throw StateError('$call: the reporter is broken');
    if (failing) {
      return Future<void>.error(StateError('$call: the reporter is offline'));
    }
    return null;
  }

  /// Forgets what was recorded: the reports, the log lines and the lines. The session's [keys] stay,
  /// as they do in Crashlytics, since the sink sends an unchanged key only once.
  void clear() {
    errors.clear();
    logs.clear();
    lines.clear();
    _keyValues.clear();
  }
}

/// A report a [RecordingCrashlytics] was given (since 0.18.0).
final class RecordedError {
  /// Describes one report.
  const RecordedError(this.error, this.stackTrace, this.reason, this.keys);

  /// The error object the app threw: the very object, not a copy.
  final Object error;

  /// Its stack trace, when the sink had one.
  final StackTrace? stackTrace;

  /// The line the console shows with the report, for example
  /// `in data items/$id/data.dart on /items/:id`.
  final String reason;

  /// The session's keys when the report was recorded, its own keys merged in. A snapshot: a later
  /// key does not change it.
  final Map<String, String> keys;
}
