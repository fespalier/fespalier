import 'package:clock/clock.dart' as time;

import 'ports.dart';
import 'request.dart';
import 'status.dart';
import 'transfer_telemetry.dart';

/// Called with each change of a download's status (since 0.15.0).
typedef DownloadObserver = void Function(String id, DownloadStatus status);

/// The download engine (since 0.15.0): the app's one place that starts, pauses, resumes, retries,
/// cancels and removes downloads, and that knows where each one stands. It owns no transfer: a
/// [DownloadBackend] does that, and a [DownloadStore] keeps what the app asked for across
/// restarts. It imports no Riverpod, so it runs in a test or a background isolate as it is.
///
/// Every download id has a **generation**. A cancel, a remove, a restart and [clearAccount] each
/// move it on, and anything an older attempt was going to do after an `await` is dropped, so a
/// late answer never writes over a newer state. An event for an id the engine does not know (or
/// has ended) is dropped too.
///
/// It starts no timer and listens to nothing: the backend calls in through [DownloadEvents], and
/// [observe] is a callback the owner hands over.
class Downloads {
  /// An engine over [backend] and [store]. [files] lets it delete a file on [remove] and
  /// [cancel] and check what a restart left; [clock] is for a test.
  Downloads({
    required DownloadBackend backend,
    required DownloadStore store,
    DownloadFiles? files,
    time.Clock? clock,
  }) : _backend = backend,
       _store = store,
       _files = files,
       _clock = clock {
    _events = _Events(this);
  }

  final DownloadBackend _backend;
  final DownloadStore _store;
  final DownloadFiles? _files;
  final time.Clock? _clock;
  late final _Events _events;

  final Map<String, DownloadStatus> _statuses = {};
  final Map<String, DownloadRequest> _requests = {};
  final Map<String, int> _generations = {};
  final Map<String, Object?> _spans = {};
  final Set<String> _reported = {};

  DownloadObserver? _observer;
  bool _open = false;
  bool _reconciling = false;
  Future<void>? _opening;

  /// When this engine last changed a status, for an app that shows "updated at" (null before
  /// the first change). Read through `package:clock`, so a test moves it.
  DateTime? get lastChange => _lastChange;
  DateTime? _lastChange;

  /// Whether [open] has finished and [close] has not been called.
  bool get isOpen => _open;

  /// The status of every download the engine knows, by id. A copy.
  Map<String, DownloadStatus> get statuses => Map.unmodifiable(_statuses);

  /// Where the download [id] stands; [Absent] when it is unknown.
  DownloadStatus statusOf(String id) => _statuses[id] ?? const Absent();

  /// Sets the one owner of status changes, replacing any earlier one; null clears it. [close]
  /// clears it too, so an engine that outlives its owner holds nothing of it.
  void observe(DownloadObserver? onChange) {
    _observer = onChange;
  }

  /// Opens the backend and settles the registry with what it reports.
  ///
  /// Every entry of the store starts as [Queued] and the backend's replay (`DownloadEvents.status`
  /// during [DownloadBackend.open]) moves it on. An entry that ended while the app was not
  /// running ends [Complete] or [Failed], and is reported as `fespalier.download.reconciled`; an
  /// entry the backend did not mention ends [Complete] when [DownloadFiles] finds its file
  /// (with the size the request names, if it does) and [Failed] with [DownloadFailure.killed]
  /// otherwise. Calling it twice does the work once.
  Future<void> open() => _opening ??= _open0();

  Future<void> _open0() async {
    final stored = await _store.load();
    _requests
      ..clear()
      ..addEntries(stored.entries.map((e) => MapEntry(e.key, e.value.request)));
    for (final entry in stored.entries) {
      final g = _generations[entry.key] ?? 0;
      _generations[entry.key] = entry.value.generation > g
          ? entry.value.generation
          : g;
      _statuses[entry.key] = const Queued();
    }
    _open = true;
    _reconciling = true;
    try {
      await _backend.open(_events);
    } finally {
      _reconciling = false;
    }
    final unmentioned = _requests.keys
        .where((id) => !_reported.contains(id))
        .toList();
    for (final id in unmentioned) {
      final settled = await _settleUnmentioned(id);
      if (settled != null) _apply(id, settled, reconciled: true);
    }
    _reported.clear();
  }

  Future<DownloadStatus?> _settleUnmentioned(String id) async {
    final request = _requests[id];
    if (request == null) return null;
    final generation = _generationOf(id);
    final files = _files;
    if (files != null) {
      final length = await files.length(request.file);
      if (generation != _generationOf(id)) return null;
      final wanted = request.bytes;
      if (length != null && (wanted == null || wanted == length)) {
        return Complete(request.file, length);
      }
    }
    return const Failed(DownloadFailure.killed);
  }

  /// Unregisters from the backend, closes it and clears the observer. The transfers the
  /// platform owns go on. Calling it twice does nothing the second time.
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _opening = null;
    _observer = null;
    for (final token in _spans.values) {
      transferFinish(token, const Cancelled());
    }
    _spans.clear();
    await _backend.close();
  }

  /// Starts the download [request].
  ///
  /// An invalid request (or a location that is not a safe relative path) ends
  /// `Failed(invalidRequest)` and is not registered: it never throws. A `userInitiated`
  /// request on a backend with no notifications ends `Failed(notificationsRequired)`. Starting
  /// an id that is already running, paused or complete does nothing: it is the same download.
  Future<void> start(DownloadRequest request) async {
    if (!_open) throw StateError('Downloads.start before open()');
    final id = request.id;
    if (!request.isValid) {
      _failEarly(id, DownloadFailure.invalidRequest);
      return;
    }
    final current = statusOf(id);
    if (_isActive(current) || current is Complete) return;
    if (request.priority == DownloadPriority.userInitiated &&
        !_backend.capabilities.notifications) {
      _failEarly(id, DownloadFailure.notificationsRequired);
      return;
    }
    await _begin(request, resumed: false);
  }

  /// Pauses the download [id]. True when the backend took the request; the status moves when it
  /// reports [Paused]. False when the download is not running or the backend cannot pause.
  Future<bool> pause(String id) async {
    final current = statusOf(id);
    if (!(current is Running || current is Queued || current is Waiting)) {
      return false;
    }
    if (!_backend.capabilities.pause) return false;
    return _backend.pause(id);
  }

  /// Resumes the paused download [id]. True when the backend took the request.
  Future<bool> resume(String id) async {
    if (statusOf(id) is! Paused) return false;
    final generation = _generationOf(id);
    final ok = await _backend.resume(id);
    if (!ok) return false;
    if (generation == _generationOf(id) && statusOf(id) is Paused) {
      _apply(id, const Queued());
    }
    return true;
  }

  /// Starts a failed download [id] again from its registered request. A size or digest mismatch
  /// deletes the file first. Does nothing for an id that is not [Failed] or whose request was
  /// never registered (an invalid one: [start] it again).
  Future<void> retry(String id) async {
    final current = statusOf(id);
    final request = _requests[id];
    if (current is! Failed || request == null) return;
    if (current.failure == DownloadFailure.notificationsRequired &&
        !_backend.capabilities.notifications &&
        request.priority == DownloadPriority.userInitiated) {
      return;
    }
    final generation = _bump(id);
    await _backend.cancel(id);
    if (generation != _generationOf(id)) return;
    if (current.failure == DownloadFailure.sizeMismatch ||
        current.failure == DownloadFailure.hashMismatch) {
      await _files?.delete(request.file);
      if (generation != _generationOf(id)) return;
    }
    await _begin(request, resumed: false, bumped: true);
  }

  /// Stops the download [id] for good and drops it from the registry. A finished download is
  /// not touched (use [remove]). The status becomes [Cancelled].
  Future<void> cancel(String id) async {
    final request = _requests[id];
    final current = statusOf(id);
    if (request == null || current is Complete) return;
    final generation = _bump(id);
    _requests.remove(id);
    _apply(id, const Cancelled());
    await _backend.cancel(id);
    // A start of the same id while the backend stopped the old one owns the registry entry and
    // the files now.
    if (generation != _generationOf(id)) return;
    await _store.remove(id);
    if (generation != _generationOf(id)) return;
    await _files?.delete(request.file);
  }

  /// Forgets the download [id]: stops it, deletes its file and drops it from the registry. The
  /// status becomes [Absent].
  Future<void> remove(String id) async {
    final request = _requests[id];
    if (request == null && !_statuses.containsKey(id)) return;
    final generation = _bump(id);
    _requests.remove(id);
    final span = _spans.remove(id);
    transferFinish(span, const Cancelled());
    if (_statuses.remove(id) != null) _notify(id, const Absent());
    await _backend.cancel(id);
    // As in cancel: a start during the wait keeps its entry and its files.
    if (generation != _generationOf(id)) return;
    await _store.remove(id);
    if (generation != _generationOf(id)) return;
    if (request != null) await _files?.delete(request.file);
  }

  /// Where the finished download [id] is on this device now, or null while it is not
  /// [Complete]. Never store the path: resolve it again when you need it.
  Future<String?> pathOf(String id) async {
    final current = statusOf(id);
    if (current is! Complete) return null;
    return _backend.resolve(current.file);
  }

  /// Sign-out: cancels every download, deletes the files and the registry, and moves every
  /// generation on so that nothing an earlier attempt was going to do, and no later event,
  /// reaches the next account.
  Future<void> clearAccount() async {
    final stored = await _store.load();
    final requests = <String, DownloadRequest>{
      for (final e in stored.entries) e.key: e.value.request,
      ..._requests,
    };
    for (final id in {..._generations.keys, ...requests.keys}) {
      _bump(id);
    }
    final known = _statuses.keys.toList();
    for (final token in _spans.values) {
      transferFinish(token, const Cancelled());
    }
    _spans.clear();
    _requests.clear();
    _statuses.clear();
    _reported.clear();
    for (final id in known) {
      _notify(id, const Absent());
    }
    await _backend.cancelAll();
    final files = _files;
    if (files != null) {
      for (final request in requests.values) {
        await files.delete(request.file);
      }
    }
    await _store.clear();
  }

  bool _isActive(DownloadStatus s) =>
      s is Queued ||
      s is Waiting ||
      s is Running ||
      s is Paused ||
      s is Verifying;

  int _generationOf(String id) => _generations[id] ?? 0;

  int _bump(String id) => _generations[id] = _generationOf(id) + 1;

  void _failEarly(String id, DownloadFailure failure) {
    _bump(id);
    _apply(id, Failed(failure));
  }

  Future<void> _begin(
    DownloadRequest request, {
    required bool resumed,
    bool bumped = false,
  }) async {
    final id = request.id;
    final generation = bumped ? _generationOf(id) : _bump(id);
    _requests[id] = request;
    _spans.remove(id);
    _spans[id] = transferBegin(
      request,
      resumed: resumed,
      background: _backend.capabilities.background,
    );
    _apply(id, const Queued());
    await _store.put(StoredDownload(request, generation: generation));
    if (generation != _generationOf(id)) return;
    final accepted = await _backend.enqueue(request);
    if (generation != _generationOf(id)) return;
    if (!accepted) _apply(id, const Failed(DownloadFailure.other));
  }

  void _onStatus(String id, DownloadStatus status, int? httpStatus) {
    if (!_open || !_requests.containsKey(id)) return;
    if (_reconciling) _reported.add(id);
    final current = _statuses[id];
    if (current is Complete || current is Failed || current is Cancelled) {
      return;
    }
    var next = status;
    if (next is Failed && (httpStatus == 401 || httpStatus == 403)) {
      next = const Failed(DownloadFailure.unauthorized);
    }
    if (next is Absent) return;
    if (next is Cancelled) {
      // The platform cancelled it (the person did, from a notification): same as our cancel.
      _cancelQuietly(id);
      return;
    }
    _apply(id, next, reconciled: _reconciling);
  }

  void _cancelQuietly(String id) {
    cancel(id).then<void>((_) {}, onError: (Object _) {});
  }

  void _apply(String id, DownloadStatus status, {bool reconciled = false}) {
    if (_statuses[id] == status) return;
    _statuses[id] = status;
    _lastChange = (_clock ?? time.clock).now();
    final terminal =
        status is Complete || status is Failed || status is Cancelled;
    if (terminal) {
      final span = _spans.remove(id);
      if (span != null) {
        transferFinish(span, status);
      } else if (reconciled && status is! Cancelled) {
        reconciledReport(status);
      }
    } else if (!_spans.containsKey(id) && _open) {
      final request = _requests[id];
      if (request != null && _reconciling) {
        // Found running after a restart: the span covers the rest of it.
        _spans[id] = transferBegin(
          request,
          resumed: true,
          background: _backend.capabilities.background,
        );
      }
    }
    _notify(id, status);
  }

  void _notify(String id, DownloadStatus status) {
    final observer = _observer;
    if (observer == null) return;
    try {
      observer(id, status);
    } catch (_) {
      // An observer that throws costs its own update, never the download.
    }
  }
}

final class _Events implements DownloadEvents {
  _Events(this._engine);

  final Downloads _engine;

  @override
  void status(String id, DownloadStatus status, {int? httpStatus}) =>
      _engine._onStatus(id, status, httpStatus);

  @override
  void tapped(String id, DownloadTapKind kind) {}
}
