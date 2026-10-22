import 'package:fespalier/fespalier.dart';

import 'backend.dart';

/// Starts an `auth` span for [step] (`restore`, `sign_in`, `renew`, `sign_out`) on the sink
/// installed with `FespalierTelemetry.install`, if there is one: with none it is one null check.
///
/// Only the step, the backend's constant name, the renewal [trigger] and the scheme's constant
/// name (`AuthBackend.scheme`) are ever reported: never a credential, a signature, a `jti`, an
/// attestation, an id, a claim, an e-mail or a URL. Auth spans need no
/// `telemetry: true`: they follow the installed sink.
Object? authSpan(String step, AuthBackend backend, {String? trigger}) {
  if (FespalierTelemetry.current == null) return null;
  return FespalierTelemetry.begin(
    TelemetryStart(
      TelemetryOp.auth,
      authStep: step,
      authBackend: backend.name,
      authTrigger: trigger,
      authScheme: backend.scheme,
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
