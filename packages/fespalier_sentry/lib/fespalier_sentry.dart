/// fespalier's telemetry in Sentry (since 0.9.0): errors and crashes tagged with the route pattern,
/// the app file and the action, page breadcrumbs, release health, and the OpenTelemetry trace each
/// event belongs to; screen-load transactions and spans on request.
///
/// ```dart
/// FespalierTelemetry.install(FespalierSentry());
/// ```
///
/// `package:fespalier_sentry/testing.dart` has `RecordingSentry`, a real Sentry hub whose
/// transport keeps what it would send, for tests.
library;

export 'src/fespalier_sentry.dart' show FespalierSentry;
