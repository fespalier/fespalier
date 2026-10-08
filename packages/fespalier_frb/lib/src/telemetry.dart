import 'package:fespalier/fespalier.dart';

/// The operation name of the core's initialisation (`TelemetryOp.custom`, since 0.13.0).
const String frbInitOp = 'fespalier.frb.init';

/// The result attribute of the initialisation: `ok` or `error`.
const String frbResultAttribute = 'fespalier.frb.result';

/// Runs a Rust core's initialisation for `startup()` and reports it (since 0.13.0).
///
/// ```dart
/// // lib/app/startup.dart
/// Future<void> startup() => initRustCore(RustLib.init);
/// ```
///
/// [init] is the generated `RustLib.init` (or a closure around it, for its arguments). The span
/// `fespalier.frb.init` ends `ok` or `error` and carries nothing else: never the error's text. A
/// failure is rethrown unchanged, so the startup gate reports it, shows `splash.dart`'s error and
/// can retry it. With no telemetry sink installed this is one null check around `init`.
Future<void> initRustCore(Future<void> Function() init) async {
  final traced = FespalierTelemetry.current != null;
  final token = traced
      ? FespalierTelemetry.begin(
          const TelemetryStart(TelemetryOp.custom, name: frbInitOp),
        )
      : null;
  try {
    await init();
  } catch (error, stackTrace) {
    if (traced) {
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          error: error,
          stackTrace: stackTrace,
          attributes: const {frbResultAttribute: 'error'},
        ),
      );
    }
    rethrow;
  }
  if (traced) {
    FespalierTelemetry.finish(
      token,
      const TelemetryEnd(
        TelemetryOutcome.ok,
        isAsync: true,
        attributes: {frbResultAttribute: 'ok'},
      ),
    );
  }
}
