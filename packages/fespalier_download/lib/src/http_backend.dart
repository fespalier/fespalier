import 'dart:async';

import 'package:http/http.dart' as http;

import 'location.dart';
import 'ports.dart';
import 'request.dart';
import 'status.dart';
import 'transfer.dart';
import 'transfer_files.dart';

/// The absolute path of a base folder on this device (since 0.15.0), as the app knows it: the
/// package depends on no plugin for it. With `path_provider`:
///
/// ```dart
/// Future<String> bases(DownloadBase base) async => switch (base) {
///   DownloadBase.support => (await getApplicationSupportDirectory()).path,
///   DownloadBase.cache => (await getApplicationCacheDirectory()).path,
///   DownloadBase.documents => (await getApplicationDocumentsDirectory()).path,
/// };
/// ```
///
/// It may throw `UnsupportedError` (the web), which ends a download `Failed(unsupported)`.
typedef DownloadBases = Future<String> Function(DownloadBase base);

/// The absolute path of [location] under the folder [bases] names for its base.
Future<String> resolveLocation(
  DownloadBases bases,
  DownloadLocation location,
) async {
  if (!location.isValid) {
    throw ArgumentError.value(
      location.base.name,
      'location',
      'not a safe path',
    );
  }
  final root = await bases(location.base);
  final trimmed = root.endsWith('/') || root.endsWith(r'\')
      ? root.substring(0, root.length - 1)
      : root;
  return '$trimmed/${location.path}';
}

/// A [DownloadFiles] over [TransferFiles] and the folders of [DownloadBases] (since 0.15.0): what
/// the engine checks after a restart and deletes on cancel, remove and sign-out. Deleting a
/// location deletes the finished file and the partial file and validator next to it. Where there
/// are no files (the web) nothing exists and a delete does nothing.
class TransferDownloadFiles implements DownloadFiles {
  /// Files under the folders [bases] names. [files] defaults to the platform's.
  TransferDownloadFiles({required this.bases, TransferFiles? files})
    : _files = files ?? defaultTransferFiles();

  /// The base folders.
  final DownloadBases bases;
  final TransferFiles _files;

  @override
  Future<bool> exists(DownloadLocation location) async =>
      await length(location) != null;

  @override
  Future<int?> length(DownloadLocation location) async {
    if (!_files.isSupported) return null;
    return _files.length(await resolveLocation(bases, location));
  }

  @override
  Future<void> delete(DownloadLocation location) async {
    if (!_files.isSupported) return;
    final path = await resolveLocation(bases, location);
    await _files.delete('$path.part');
    await _files.delete('$path.part.etag');
    await _files.delete(path);
  }
}

enum _Phase { running, paused, ended }

// One download the backend knows: its request, its current attempt and where that stands.
final class _Entry {
  _Entry(this.request);

  DownloadRequest request;
  _Phase phase = _Phase.ended;
  _Attempt? attempt;
  String? destination;
}

// One attempt: made when a download starts or resumes, over when its transfer ends.
final class _Attempt {
  final Completer<void> done = Completer<void>();
  HttpTransfer? transfer;
  bool pauseAsked = false;
  bool stopped = false;

  void pause() {
    pauseAsked = true;
    transfer?.pause();
  }

  void stop() {
    stopped = true;
    transfer?.stop();
  }
}

/// The foreground download backend (since 0.15.0): `HttpTransfer`s over an `http.Client` the app
/// provides (so its timeouts, proxy and certificates apply), reporting to the engine through
/// [DownloadEvents]. It works while the app runs and holds nothing on the operating system's
/// side, so its [capabilities] are honest: it can pause, and that is all. No background, no
/// notifications, no `unmetered` (a request that asks for it is refused), and a transfer does
/// not survive the app being closed: after a restart the engine finds the download ended, and
/// `Downloads.retry` goes on from the partial file with a `Range` request.
///
/// A download is paused with [pause] (the request is aborted and the partial file kept) and
/// goes on with [resume]. [cancel] stops a transfer and deletes the partial file it was
/// keeping; a transfer that already ended keeps its partial file, so that `retry` can continue
/// it. Every start runs at once: there is no limit of parallel transfers.
///
/// On the web (no `dart:io`) every enqueued download ends `Failed(unsupported)` before any
/// request is made. It starts no timer and listens to nothing.
///
/// Nothing a server or a file said is reported: a failure is a [DownloadFailure] value, with the
/// HTTP status code of a refusal.
class HttpDownloadBackend implements DownloadBackend {
  /// A backend downloading with [client] into the folders [bases] names. [files] defaults to the
  /// platform's. The backend never closes [client].
  HttpDownloadBackend({
    required http.Client client,
    required this.bases,
    TransferFiles? files,
  }) : _client = client,
       _files = files ?? defaultTransferFiles();

  final http.Client _client;
  final TransferFiles _files;

  /// The base folders.
  final DownloadBases bases;

  DownloadEvents? _events;
  final Map<String, _Entry> _entries = {};
  // Bumped by every start and cancel of an id and never reset, so an attempt that is over (or
  // was replaced) cannot change the state.
  final Map<String, int> _generations = {};

  @override
  DownloadCapabilities get capabilities =>
      const DownloadCapabilities(pause: true);

  @override
  Future<void> open(DownloadEvents events) async {
    _events = events;
  }

  @override
  Future<void> close() async {
    _events = null;
    final attempts = [
      for (final entry in _entries.values)
        if (entry.attempt != null) entry.attempt!,
    ];
    for (final attempt in attempts) {
      attempt.stop();
    }
    for (final attempt in attempts) {
      await attempt.done.future;
    }
    _entries.clear();
  }

  int _generationOf(String id) => _generations[id] ?? 0;

  int _bump(String id) => _generations[id] = _generationOf(id) + 1;

  bool _current(String id, int generation) =>
      _events != null && _generationOf(id) == generation;

  void _report(
    String id,
    int generation,
    DownloadStatus status, {
    int? httpStatus,
  }) {
    if (!_current(id, generation)) return;
    _events?.status(id, status, httpStatus: httpStatus);
  }

  @override
  Future<bool> enqueue(
    DownloadRequest request, {
    Map<String, String> authorization = const {},
  }) async {
    final id = request.id;
    if (_events == null) return false;
    // The foreground cannot tell a metered network from another: refuse rather than spend data
    // the app said not to.
    if (request.network == DownloadNetwork.unmetered) return false;
    if (!request.isValid || _destinationTaken(request)) {
      _report(
        id,
        _generationOf(id),
        const Failed(DownloadFailure.invalidRequest),
      );
      return true;
    }
    final entry = _entries[id];
    if (entry != null && entry.phase != _Phase.ended) return true;
    final next = entry ?? (_entries[id] = _Entry(request));
    next.request = request;
    _begin(next, authorization);
    return true;
  }

  // Two downloads must not write one file.
  bool _destinationTaken(DownloadRequest request) {
    for (final other in _entries.entries) {
      if (other.key != request.id && other.value.request.file == request.file) {
        return true;
      }
    }
    return false;
  }

  // Starts a new attempt of [entry]: the transfer runs on its own, and its end is reported.
  void _begin(_Entry entry, Map<String, String> authorization) {
    final request = entry.request;
    final id = request.id;
    final generation = _bump(id);
    final earlier = entry.attempt;
    final attempt = _Attempt();
    entry.attempt = attempt;
    entry.phase = _Phase.running;
    unawaited(_drive(entry, generation, attempt, earlier, authorization));
  }

  Future<void> _drive(
    _Entry entry,
    int generation,
    _Attempt attempt,
    _Attempt? earlier,
    Map<String, String> authorization,
  ) async {
    final request = entry.request;
    final id = request.id;
    try {
      // An earlier attempt of this id (a cancel is still stopping it) closes its file first:
      // two never write the same one.
      if (earlier != null) await earlier.done.future;
      if (!_current(id, generation) || attempt.stopped) return;
      if (!_files.isSupported) {
        _end(entry, generation, const Failed(DownloadFailure.unsupported));
        return;
      }
      final String destination;
      try {
        destination = entry.destination = await resolveLocation(
          bases,
          request.file,
        );
      } catch (error) {
        _end(
          entry,
          generation,
          Failed(
            error is UnsupportedError
                ? DownloadFailure.unsupported
                : DownloadFailure.storage,
          ),
        );
        return;
      }
      if (!_current(id, generation) || attempt.stopped) return;
      final transfer = HttpTransfer(
        client: _client,
        files: _files,
        url: request.url,
        destination: destination,
        headers: {...request.headers, ...authorization},
        bytes: request.bytes,
        sha256: request.sha256,
        onProgress: (received, total) =>
            _report(id, generation, Running(received, total)),
        onVerifying: () => _report(id, generation, const Verifying()),
      );
      attempt.transfer = transfer;
      if (attempt.pauseAsked) transfer.pause();
      final result = await transfer.run();
      if (!_current(id, generation)) return;
      switch (result) {
        case TransferDone(:final bytes):
          _end(entry, generation, Complete(request.file, bytes));
        case TransferPaused(:final received, :final total):
          entry.phase = _Phase.paused;
          _report(id, generation, Paused(received, total));
        case TransferFailed(:final failure, :final httpStatus):
          _end(entry, generation, Failed(failure), httpStatus: httpStatus);
        case TransferStopped():
          break;
      }
    } catch (error) {
      _end(
        entry,
        generation,
        Failed(
          error is UnsupportedError
              ? DownloadFailure.unsupported
              : DownloadFailure.other,
        ),
      );
    } finally {
      if (identical(entry.attempt, attempt)) entry.attempt = null;
      attempt.done.complete();
    }
  }

  void _end(
    _Entry entry,
    int generation,
    DownloadStatus status, {
    int? httpStatus,
  }) {
    if (!_current(entry.request.id, generation)) return;
    entry.phase = _Phase.ended;
    _report(entry.request.id, generation, status, httpStatus: httpStatus);
  }

  @override
  Future<bool> pause(String id) async {
    final entry = _entries[id];
    final attempt = entry?.attempt;
    if (entry == null || attempt == null || entry.phase != _Phase.running) {
      return false;
    }
    attempt.pause();
    await attempt.done.future;
    return entry.phase == _Phase.paused;
  }

  @override
  Future<bool> resume(
    String id, {
    Map<String, String> authorization = const {},
  }) async {
    final entry = _entries[id];
    if (entry == null || _events == null || entry.phase != _Phase.paused) {
      return false;
    }
    _begin(entry, authorization);
    return true;
  }

  @override
  Future<void> cancel(String id) => _cancel(id, deleteKept: null);

  @override
  Future<void> cancelAll() async {
    for (final id in _entries.keys.toList()) {
      await _cancel(id, deleteKept: true);
    }
  }

  // Stops [id] and forgets it. The partial file is deleted when [deleteKept] is true, or, when
  // it is null, when a transfer was running or paused (a transfer that ended keeps it).
  Future<void> _cancel(String id, {required bool? deleteKept}) async {
    final entry = _entries[id];
    if (entry == null) return;
    final generation = _bump(id);
    final inProgress = entry.phase != _Phase.ended;
    // From now on a start of the same id begins a new attempt, which waits for this one to end.
    entry.phase = _Phase.ended;
    final attempt = entry.attempt;
    // The request is aborted; the transfer closes its file before the files are deleted.
    attempt?.stop();
    if (attempt != null) await attempt.done.future;
    // A start of the same id while this waited has taken the id over.
    if (_generationOf(id) != generation) return;
    if (deleteKept ?? inProgress) {
      try {
        final path =
            entry.destination ??
            await resolveLocation(bases, entry.request.file);
        await _files.delete('$path.part');
        await _files.delete('$path.part.etag');
      } catch (_) {
        // The engine deletes the files through DownloadFiles and reports a failure there.
      }
    }
    if (_generationOf(id) != generation) return;
    _entries.remove(id);
  }

  @override
  Future<String> resolve(DownloadLocation location) =>
      resolveLocation(bases, location);

  @override
  Future<void> configureNotifications(
    DownloadNotifications? notifications,
  ) async {
    // The foreground backend shows none: capabilities.notifications is false.
  }
}
