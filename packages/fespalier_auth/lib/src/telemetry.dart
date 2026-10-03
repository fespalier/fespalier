import 'package:fespalier/fespalier.dart';

import 'backend.dart';

/// Starts an `auth` span for [step] (`restore`, `sign_in`, `refresh`, `sign_out`) on the sink
/// installed with `FespalierTelemetry.install`, if there is one: with none it is one null check.
///
/// Only the step, the backend's constant name, the refresh [trigger] and whether tokens are
/// bound are ever reported: never a token, an id, a claim, an e-mail or a URL. Auth spans need no
/// `telemetry: true`: they follow the installed sink.
Object? authSpan(String step, AuthBackend backend, {String? trigger}) {
  if (FespalierTelemetry.current == null) return null;
  return FespalierTelemetry.begin(
    TelemetryStart(
      TelemetryOp.auth,
      authStep: step,
      authBackend: backend.name,
      authTrigger: trigger,
      authDpop: backend.proof != null,
    ),
  );
}

/// Ends the span [token] came from with [outcome], one of the `TelemetryOutcome` values.
void authSpanEnd(
  Object? token,
  String outcome, {
  bool isAsync = true,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (FespalierTelemetry.current == null) return;
  FespalierTelemetry.finish(
    token,
    TelemetryEnd(
      outcome,
      isAsync: isAsync,
      error: error,
      stackTrace: stackTrace,
    ),
  );
}
