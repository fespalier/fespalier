/// OpenTelemetry for fespalier (since 0.8.0): `FespalierOtel` turns what fespalier reports while
/// it routes into spans, on the SDK that `otel_zone` (or the app) started, and
/// `FespalierConventions` holds every name it emits.
library;

export 'src/conventions.dart';
export 'src/fespalier_otel.dart';
