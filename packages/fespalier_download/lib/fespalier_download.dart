/// Downloads for fespalier (since 0.15.0): the model and the ports of a file transfer that
/// outlives a screen, the `Downloads` engine over them, and the telemetry names. Pure Dart over
/// `package:http`, with no platform plugin; `HttpDownloadBackend` is the foreground transfer, `FileDownloadStore` the durable registry and
/// `downloads` / `downloadStatus` the Riverpod providers a widget watches.
/// The fakes are in `package:fespalier_download/testing.dart`.
library;

export 'src/engine.dart';
export 'src/file_store.dart';
export 'src/http_backend.dart';
export 'src/location.dart';
export 'src/ports.dart';
export 'src/providers.dart';
export 'src/request.dart';
export 'src/status.dart';
export 'src/telemetry.dart';
export 'src/transfer.dart';
export 'src/transfer_files.dart';
