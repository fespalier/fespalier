import 'package:fespalier/fespalier.dart'
    show
        FespalierTelemetry,
        TelemetryEnd,
        TelemetryOp,
        TelemetryOutcome,
        TelemetryStart;
import 'package:fespalier_download/fespalier_download.dart';

import 'upload_request.dart';

/// The names uploads report (since 0.15.0), as `TelemetryOp.custom` operations: a namespace of
/// their own next to `FespalierDownloadConventions`, so that no download name changes. Pinned by
/// `test/upload_telemetry_test.dart`: add a key, never rename one.
///
/// Every value is a constant, a boolean or the name of an enum: **never a URL, an id, a path, a
/// field name or value, a display name, a header or an error's text.**
abstract final class FespalierUploadConventions {
  /// One upload, from its start to how it ended.
  static const String transfer = 'fespalier.upload.transfer';

  /// Start attribute: whether a backend ran it outside the app (`bool`).
  static const String background = 'fespalier.upload.background';

  /// Start attribute: the request's `DownloadNetwork` name.
  static const String network = 'fespalier.upload.network';

  /// Start attribute: the request's `DownloadPriority` name.
  static const String priority = 'fespalier.upload.priority';

  /// Start attribute: the request's `UploadEncoding` name.
  static const String encoding = 'fespalier.upload.encoding';

  /// Start attribute: whether the request is replay safe (`bool`).
  static const String replaySafe = 'fespalier.upload.replay_safe';

  /// End attribute: [resultComplete], [resultFailed] or [resultCancelled].
  static const String result = 'fespalier.upload.result';

  /// End attribute when it failed: the `DownloadFailure` name.
  static const String failure = 'fespalier.upload.failure';

  /// End attribute, present only when true (`bool`): the upload was refused (401 or 403) and the
  /// engine asked the app's grantor for a renewed grant.
  static const String regranted = 'fespalier.upload.regranted';

  /// [result] value: the server took it.
  static const String resultComplete = 'complete';

  /// [result] value: it ended without the server's answer.
  static const String resultFailed = 'failed';

  /// [result] value: the app stopped it.
  static const String resultCancelled = 'cancelled';

  /// The engine settled the registry at open (an upload that ended while the app was away).
  static const String reconciled = 'fespalier.upload.reconciled';
}

/// Starts the span of one upload, or returns null when no sink is installed. Never throws.
Object? uploadBegin(UploadRequest request, {required bool background}) {
  if (FespalierTelemetry.current == null) return null;
  try {
    return FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.custom,
        name: FespalierUploadConventions.transfer,
        attributes: {
          FespalierUploadConventions.background: background,
          FespalierUploadConventions.network: request.network.name,
          FespalierUploadConventions.priority: request.priority.name,
          FespalierUploadConventions.encoding: request.encoding.name,
          FespalierUploadConventions.replaySafe: request.replaySafe,
        },
      ),
    );
  } catch (_) {
    // A failing sink costs the span, never the upload.
    return null;
  }
}

/// Ends the span [uploadBegin] started. Never throws, never carries an error.
void uploadFinish(
  Object? token,
  DownloadStatus status, {
  bool regranted = false,
}) {
  if (token == null) return;
  try {
    FespalierTelemetry.finish(token, _end(status, regranted: regranted));
  } catch (_) {
    // As above.
  }
}

/// Reports an upload that ended while the app was not running. Never throws.
void uploadReconciledReport(DownloadStatus status) {
  if (FespalierTelemetry.current == null) return;
  try {
    final token = FespalierTelemetry.begin(
      const TelemetryStart(
        TelemetryOp.custom,
        name: FespalierUploadConventions.reconciled,
      ),
    );
    FespalierTelemetry.finish(token, _end(status));
  } catch (_) {
    // As above.
  }
}

TelemetryEnd _end(DownloadStatus status, {bool regranted = false}) {
  return TelemetryEnd(
    status is Failed ? TelemetryOutcome.error : TelemetryOutcome.ok,
    isAsync: true,
    attributes: {
      FespalierUploadConventions.result: switch (status) {
        Complete() => FespalierUploadConventions.resultComplete,
        Failed() => FespalierUploadConventions.resultFailed,
        _ => FespalierUploadConventions.resultCancelled,
      },
      if (status is Failed)
        FespalierUploadConventions.failure: status.failure.name,
      if (regranted) FespalierUploadConventions.regranted: true,
    },
  );
}
