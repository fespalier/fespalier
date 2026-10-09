// A test rig for HttpDownloadBackend: the backend plays the platform, and the rig plays the
// engine's part with the fewest rules (it records what the backend reports, and makes the calls
// the engine would), so a test sees the backend's own behaviour.
import 'dart:async';

import 'package:fespalier_download/fespalier_download.dart';
import 'package:http/http.dart' as http;

/// The base folder every test resolves to.
const root = '/packs';

/// Where `douala.pmtiles` ends up, its partial file and its validator.
const dest = '$root/douala.pmtiles';
const part = '$dest.part';
const tag = '$part.etag';

/// The location of the default test file.
const loc = DownloadLocation(DownloadBase.support, 'douala.pmtiles');

DownloadRequest request({
  String id = 'douala',
  String path = 'douala.pmtiles',
  int? bytes,
  String? sha256,
  Map<String, String> headers = const {},
  DownloadNetwork network = DownloadNetwork.any,
  Uri? url,
}) => DownloadRequest(
  id: id,
  url: url ?? Uri.parse('https://tiles.example.com/douala.pmtiles'),
  file: DownloadLocation(DownloadBase.support, path),
  bytes: bytes,
  sha256: sha256,
  headers: headers,
  network: network,
);

Future<String> defaultBases(DownloadBase base) async => root;

class Rig implements DownloadEvents {
  Rig(http.Client client, this.files, {DownloadBases? basesOf})
    : bases = basesOf ?? defaultBases,
      backend = HttpDownloadBackend(
        client: client,
        bases: basesOf ?? defaultBases,
        files: files,
      ) {
    // open() only keeps the events, before its first await.
    unawaited(open());
  }

  final HttpDownloadBackend backend;
  final TransferFiles files;
  final DownloadBases bases;

  /// What the backend last said about each id.
  final Map<String, DownloadStatus> statuses = {};

  /// Everything it said, in order, with the id.
  final List<(String, DownloadStatus)> history = [];

  /// The HTTP status that came with the last report of each id.
  final Map<String, int?> httpStatuses = {};

  final Map<String, DownloadRequest> _requests = {};
  // Moves on with every removal, so a wait that began before it ends with it.
  final Map<String, int> _epochs = {};
  Completer<void> _next = Completer<void>();

  /// Where the default id stands.
  DownloadStatus get now => statusOf('douala');

  DownloadStatus statusOf(String id) => statuses[id] ?? const Absent();

  @override
  void status(String id, DownloadStatus status, {int? httpStatus}) {
    _set(id, status);
    httpStatuses[id] = httpStatus;
  }

  @override
  void tapped(String id, DownloadTapKind kind) {}

  /// The engine's view of the files: what it deletes on remove and retry.
  TransferDownloadFiles get engineFiles =>
      TransferDownloadFiles(bases: bases, files: files);

  Future<void> open() => backend.open(this);

  static bool _active(DownloadStatus? s) =>
      s is Queued || s is Running || s is Verifying || s is Paused;

  static bool _settled(DownloadStatus s) =>
      s is Complete ||
      s is Failed ||
      s is Paused ||
      s is Absent ||
      s is Cancelled;

  void _changed() {
    final done = _next;
    _next = Completer<void>();
    done.complete();
  }

  /// Completes when [id] has stopped: complete, failed, paused or gone.
  Future<void> settle(String id, [int? since]) async {
    final epoch = since ?? _epochs[id] ?? 0;
    while (!_settled(statusOf(id)) && (_epochs[id] ?? 0) == epoch) {
      await _next.future;
    }
  }

  /// What the engine does for `start`, then waits for the transfer to stop.
  Future<void> start(DownloadRequest r) async {
    final since = _epochs[r.id] ?? 0;
    _requests[r.id] = r;
    if (!_active(statuses[r.id])) _set(r.id, const Queued());
    await backend.enqueue(r);
    await settle(r.id, since);
  }

  Future<void> pause(String id) async {
    await backend.pause(id);
  }

  /// Resumes a paused download and waits for it to stop again.
  Future<void> resume(
    String id, {
    Map<String, String> authorization = const {},
  }) async {
    if (statuses[id] is! Paused) return;
    _set(id, const Queued());
    await backend.resume(id, authorization: authorization);
    await settle(id);
  }

  /// What `Downloads.retry` does for a failed download, then waits for the transfer to stop.
  Future<void> retry(String id) async {
    final current = statuses[id];
    final r = _requests[id];
    if (current is! Failed || r == null) return;
    await backend.cancel(id);
    if (current.failure == DownloadFailure.sizeMismatch ||
        current.failure == DownloadFailure.hashMismatch) {
      await engineFiles.delete(r.file);
    }
    _set(id, const Queued());
    await backend.enqueue(r);
    await settle(id);
  }

  /// A removal as far as the backend is concerned: the status goes, the transfer is stopped.
  Future<void> remove(String id) async {
    _requests.remove(id);
    _epochs[id] = (_epochs[id] ?? 0) + 1;
    if (statuses.remove(id) != null) _changed();
    await backend.cancel(id);
  }

  void _set(String id, DownloadStatus s) {
    statuses[id] = s;
    history.add((id, s));
    _changed();
  }
}
