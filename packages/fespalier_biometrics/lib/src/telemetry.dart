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

/// The operation name of a secret read, write or delete (`TelemetryOp.custom`, since 0.19.0).
const String biometricSecretOp = 'fespalier.biometrics.secret';

/// Which secret operation it was: `read`, `write` or `delete`.
const String biometricSecretOpAttribute = 'fespalier.biometrics.secret_op';

/// Starts a span for [op] (`read`, `write` or `delete`) on the installed sink, if there is one.
///
/// Never the key, the value or the reason.
Object? secretSpan(String op) {
  if (FespalierTelemetry.current == null) return null;
  return FespalierTelemetry.begin(
    TelemetryStart(
      TelemetryOp.custom,
      name: biometricSecretOp,
      attributes: {biometricSecretOpAttribute: op},
    ),
  );
}

/// Ends a [secretSpan] with [result] (a constant: `found`, `missing`, `success` or a [BiometricOutcome]'s
/// name). A store that threw ends in [TelemetryOutcome.error] **without** the error, whose text can name
/// the key.
void secretSpanEnd(Object? token, String result, String outcome) {
  if (FespalierTelemetry.current == null) return;
  FespalierTelemetry.finish(
    token,
    TelemetryEnd(
      outcome,
      isAsync: true,
      attributes: {biometricResultAttribute: result},
    ),
  );
}
