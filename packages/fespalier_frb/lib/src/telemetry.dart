import 'package:fespalier/fespalier.dart';

/// The operation name of the core's initialisation (`TelemetryOp.custom`, since 0.13.0).
const String frbInitOp = 'fespalier.frb.init';

/// The result attribute of `fespalier.frb.init` (`ok` or `error`) and, since 0.18.0, of
/// `fespalier.frb.decode` (`unknown` or `error`).
const String frbResultAttribute = 'fespalier.frb.result';

/// Runs a Rust core's initialisation for `startup()` and reports it (since 0.13.0).
///
/// ```dart
/// // lib/app/startup.dart
/// Future<void> startup() => initRustCore(RustLib.init);
/// ```
///
/// [init] is the generated `RustLib.init` (or a closure around it, for its arguments). The span
/// `fespalier.frb.init` ends `ok` or `error` and carries nothing else: not the error, its text or
/// its stack trace (a sink such as `FespalierOtel` would record the message). A
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
  } catch (_) {
    if (traced) {
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
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

/// The operation name of a message or batch item that a `ChangeCodec` skipped
/// (`TelemetryOp.custom`, since 0.18.0). Since 0.25.0 fespalier_stream's `EventCodec` reports the
/// span (a root span, constants and a count only) under these names for a `ChangeCodec`, and under
/// `fespalier.stream.decode` for itself.
const String frbDecodeOp = 'fespalier.frb.decode';

/// End attribute of [frbDecodeOp]: how many skips of its kind (`unknown` or `error`) the codec
/// has made so far, this one included (an `int`, since 0.18.0).
const String frbSkippedAttribute = 'fespalier.frb.skipped';
