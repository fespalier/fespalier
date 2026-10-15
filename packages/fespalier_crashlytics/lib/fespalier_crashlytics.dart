/// fespalier's telemetry in Crashlytics (since 0.18.0): every failure of a guard, a `data.dart`, an
/// action or a deferred load as a non-fatal report named by the route pattern and the app file that
/// threw, the screen as a custom key, and a log line per page change. It depends on no Firebase
/// package: the app passes a [CrashReporter] that forwards to Firebase (the recipe is in the
/// `fespalier-observability` skill).
///
/// ```dart
/// FespalierTelemetry.add(FespalierCrashlytics(FirebaseCrashReporter()));
/// ```
///
/// `package:fespalier_crashlytics/testing.dart` has `RecordingCrashlytics`, a [CrashReporter] that
/// keeps what it is given, for tests.
library;

export 'src/keys.dart' show CrashlyticsKeys;
export 'src/reporter.dart' show CrashReporter;
export 'src/sink.dart' show FespalierCrashlytics;
