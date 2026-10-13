import 'package:fespalier/fespalier.dart';

import 'prompt.dart';

/// The operation name of a prompt (`TelemetryOp.custom`, since 0.13.0).
const String biometricPromptOp = 'fespalier.biometrics.prompt';

/// The result attribute of a prompt: a [BiometricOutcome]'s name.
const String biometricResultAttribute = 'fespalier.biometrics.result';

/// Starts a prompt span on the installed sink, if there is one (one null check otherwise).
///
/// Only constants are ever reported: the operation and the outcome's name. Never the reason text.
Object? promptSpan() {
  if (FespalierTelemetry.current == null) return null;
  return FespalierTelemetry.begin(
    const TelemetryStart(TelemetryOp.custom, name: biometricPromptOp),
  );
}

/// Ends the span [token] came from with [outcome] (or [error], when the prompt threw).
void promptSpanEnd(
  Object? token,
  BiometricOutcome outcome, {
  Object? error,
  StackTrace? stackTrace,
}) {
  if (FespalierTelemetry.current == null) return;
  FespalierTelemetry.finish(
    token,
    TelemetryEnd(
      error != null
          ? TelemetryOutcome.error
          : switch (outcome) {
              BiometricOutcome.success => TelemetryOutcome.ok,
              BiometricOutcome.cancelled => TelemetryOutcome.cancelled,
              BiometricOutcome.unavailable => TelemetryOutcome.skipped,
              BiometricOutcome.failed ||
              BiometricOutcome.lockedOut => TelemetryOutcome.rejected,
            },
      isAsync: true,
      error: error,
      stackTrace: stackTrace,
      attributes: {biometricResultAttribute: outcome.name},
    ),
  );
}
