import 'package:fespalier/fespalier.dart'
    show
        FespalierTelemetry,
        TelemetryEnd,
        TelemetryOp,
        TelemetryOutcome,
        TelemetryStart;

import 'request.dart';
import 'status.dart';
import 'telemetry.dart';

/// Starts the span of one transfer, or returns null when no sink is installed (one null check).
/// Never throws. The attributes are constants, booleans and enum names: never the request's URL,
/// id, path, display name or headers.
Object? transferBegin(
  DownloadRequest request, {
  required bool resumed,
  required bool background,
}) {
  if (FespalierTelemetry.current == null) return null;
  try {
    return FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.custom,
        name: FespalierDownloadConventions.transfer,
        attributes: {
          FespalierDownloadConventions.resumed: resumed,
          FespalierDownloadConventions.background: background,
          FespalierDownloadConventions.network: request.network.name,
          FespalierDownloadConventions.priority: request.priority.name,
        },
      ),
    );
  } catch (_) {
    // A failing sink costs the span, never the download.
    return null;
  }
}

/// Ends the span [transferBegin] started, with how it ended. Never throws, and never carries an
/// error.
void transferFinish(Object? token, DownloadStatus status) {
  if (token == null) return;
  try {
    FespalierTelemetry.finish(token, _end(status));
  } catch (_) {
    // As above.
  }
}

/// Reports an entry that ended while the app was not running, as one span that starts and ends
/// at once. Never throws.
void reconciledReport(DownloadStatus status) {
  if (FespalierTelemetry.current == null) return;
  try {
    final token = FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.custom,
        name: FespalierDownloadConventions.reconciled,
      ),
    );
    FespalierTelemetry.finish(token, _end(status));
  } catch (_) {
    // As above.
  }
}

TelemetryEnd _end(DownloadStatus status) {
  return TelemetryEnd(
    status is Failed ? TelemetryOutcome.error : TelemetryOutcome.ok,
    isAsync: true,
    attributes: {
      FespalierDownloadConventions.result: switch (status) {
        Complete() => FespalierDownloadConventions.resultComplete,
        Failed() => FespalierDownloadConventions.resultFailed,
        _ => FespalierDownloadConventions.resultCancelled,
      },
      if (status is Failed)
        FespalierDownloadConventions.failure: status.failure.name,
    },
  );
}
