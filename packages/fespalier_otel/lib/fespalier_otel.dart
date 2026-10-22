/// OpenTelemetry for fespalier (since 0.8.1): `FespalierOtel` turns what fespalier reports while
/// it routes into spans, on the SDK that `otel_zone` (or the app) started, and
/// `FespalierConventions` holds every name it emits. `OtelTransport` (since 0.21.0) is a
/// `fespalier_transport` decorator that makes one `CLIENT` span for each request sent.
library;

export 'src/conventions.dart';
export 'src/fespalier_otel.dart';
export 'src/otel_transport.dart' show OtelTransport;
