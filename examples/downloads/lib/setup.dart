import 'package:downloads/app.g.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The folders downloads go in. On the web there are none: every start ends
/// `Failed(unsupported)` before this is asked, and it throws `UnsupportedError` all the same.
Future<String> bases(DownloadBase base) async {
  if (kIsWeb) throw UnsupportedError('no files on the web');
  return switch (base) {
    DownloadBase.support => (await getApplicationSupportDirectory()).path,
    DownloadBase.cache => (await getTemporaryDirectory()).path,
    DownloadBase.documents => (await getApplicationDocumentsDirectory()).path,
  };
}

/// A grant the demo's "server" gave, as the detail page lists it: whether it followed a 401 or
/// 403, never the grant itself.
final List<({String id, bool renewal})> grantLog = [];

/// The grantor of this demo.
///
/// A real app makes its signed request here and returns the short-lived URL the server answered
/// with (docs/downloads.md, "Credentials"). The demo has no server: it returns a header that
/// is harmless to any file host, and writes down that it was asked. There is no secret in it.
DownloadGrant? demoGrantor(DownloadRequest request, {required bool renewal}) {
  grantLog.add((id: request.id, renewal: renewal));
  return DownloadGrant(headers: {'X-Demo-Grant': 'grant-${grantLog.length}'});
}

DownloadFiles? _files;

/// The files the engine writes, for the detail page to ask what is on disk. Set by
/// [configureDownloads].
DownloadFiles get demoFiles =>
    _files ?? (throw StateError('configureDownloads() was not called'));

/// What a tap on a download's notification opens: that download's page. The foreground backend
/// shows no notification, so on a phone nothing taps this; the background backend
/// (`fespalier_download_background`) does, and the tests play the tap.
DownloadTarget? tapTarget(DownloadTap tap) {
  final request = tap.request;
  if (request == null) return null; // a download this account no longer has
  return DownloadTarget.to(FileRoute(id: request.id));
}

/// Configures `fespalier_download` before `AppMain.run()`. It is the app with the app's one
/// [transport] (`main()` builds it): the foreground [HttpDownloadBackend] sends through it, with a
/// [FileDownloadStore] registry and the files of [bases]. A test passes fakes instead, and no
/// transport.
void configureDownloads({
  HttpTransport? transport,
  DownloadBackend? backend,
  DownloadStore? store,
  DownloadFiles? files,
}) {
  if (backend == null && transport == null) {
    throw ArgumentError(
      'configureDownloads needs the app\'s transport, or a backend of its own',
    );
  }
  final realFiles = TransferDownloadFiles(bases: bases);
  _files = files ?? realFiles;
  FespalierDownload.configure(
    backend:
        backend ?? HttpDownloadBackend(transport: transport!, bases: bases),
    store: store ?? FileDownloadStore(bases: bases),
    files: _files,
    grantor: demoGrantor,
    route: tapTarget,
  );
}
