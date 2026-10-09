/// The names fespalier_download reports (since 0.15.0), as `TelemetryOp.custom` operations. The
/// package's own contract, pinned by `test/telemetry_test.dart`: add a key, never rename one.
///
/// Every value is a constant, a boolean or the name of an enum of this package: **never a URL,
/// an id, a path, a display name, a header or an error's text.**
abstract final class FespalierDownloadConventions {
  /// One transfer, from its start to how it ended.
  static const String transfer = 'fespalier.download.transfer';

  /// Start attribute of [transfer]: whether the transfer went on from bytes it already had
  /// (`bool`).
  static const String resumed = 'fespalier.download.resumed';

  /// Start attribute of [transfer]: whether a backend ran it outside the app (`bool`).
  static const String background = 'fespalier.download.background';

  /// Start attribute of [transfer]: the request's `DownloadNetwork` name.
  static const String network = 'fespalier.download.network';

  /// Start attribute of [transfer]: the request's `DownloadPriority` name.
  static const String priority = 'fespalier.download.priority';

  /// End attribute of [transfer]: [resultComplete], [resultFailed] or [resultCancelled].
  static const String result = 'fespalier.download.result';

  /// End attribute of [transfer] when it failed: the `DownloadFailure` name.
  static const String failure = 'fespalier.download.failure';

  /// [result] value: the file is in place.
  static const String resultComplete = 'complete';

  /// [result] value: it ended without a file.
  static const String resultFailed = 'failed';

  /// [result] value: the app stopped it.
  static const String resultCancelled = 'cancelled';

  /// The engine settled the registry with what the platform reports, at open.
  static const String reconciled = 'fespalier.download.reconciled';

  /// A notification tap was handled: a span from the tap to the navigation call.
  static const String open = 'fespalier.download.open';

  /// End attribute of [open]: whether the tap was mapped to a place and the navigation was made
  /// (`bool`).
  static const String routed = 'fespalier.download.routed';
}
