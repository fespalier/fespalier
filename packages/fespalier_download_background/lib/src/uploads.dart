import 'dart:async';

import 'package:clock/clock.dart' as time;
import 'package:fespalier_download/fespalier_download.dart';

import 'upload_ports.dart';
import 'upload_request.dart';
import 'upload_telemetry.dart';

/// Called with each change of an upload's status (since 0.15.0).
typedef UploadObserver = void Function(String id, DownloadStatus status);

/// Asks the app for a [DownloadGrant] (since 0.15.0) before an upload attempt: the same grant a
/// download takes, here a short-lived upload address (a pre-signed `PUT` URL) and/or headers good
/// for that upload alone. [renewal] is true for the one that follows a 401 or 403, which the
/// engine asks for **only for a replay-safe upload**. Return null to send the request as it is; a
/// throw ends the upload `Failed(unauthorized)`.
typedef UploadGrantor = FutureOr<DownloadGrant?> Function(
  UploadRequest request, {
  required bool renewal,
});

/// The upload engine (since 0.15.0): the app's one place that starts, retries, cancels and
/// removes uploads, and that knows where each one stands. It is a sibling of `Downloads`, not a
/// mode of it, because the two disagree on what a restart means: a download that left its file is
/// complete, an upload whose file is still there has told us nothing. It owns no transfer (an
/// [UploadBackend] does) and imports no Riverpod. It keeps the guarantees of `Downloads`:
/// generations that drop a late answer of an old attempt, a durable registry that is never
/// evicted and is wiped by [clearAccount], one observer slot, no timer and no listener.
///
/// **The file that is sent is the app's.** [cancel], [remove] and [clearAccount] never delete it.
///
/// **Replay safety.** An upload without an `Idempotency-Key` ([UploadRequest.replaySafe] false)
/// is a write the server may already have taken, so the engine never sends it twice by itself:
///
/// | | replay safe | not replay safe |
/// | --- | --- | --- |
/// | platform retries after a failed attempt | the backend's retries | none |
/// | 401 or 403 | one renewed grant, then sent again | `Failed(unauthorized)` |
/// | killed, or no answer after a restart | `Failed(killed)`; [retry] sends it again | `Failed(killed)`; [retry] and [start] refuse (see [outcomeUnknown]) |
/// | a lost response (`Failed(network)`) | [retry] sends it again | the same: the server may have it |
///
/// To send it again anyway, [remove] it and [start] it: that is the app's decision, made after
/// asking its server.
class Uploads {
  /// An engine over the backend and the store. `clock` is for a test; `grantor` makes the short-lived
  /// credentials of an attempt.
  Uploads({
    required this._backend,
    required this._store,
    this._clock,
    this._grantor,
  }) {
    _events = _Events(this);
  }

  final UploadBackend _backend;
  final UploadStore _store;
  final time.Clock? _clock;
  final UploadGrantor? _grantor;
  final Set<String> _regranted = {};
  late final _Events _events;

  final Map<String, DownloadStatus> _statuses = {};
  final Map<String, UploadRequest> _requests = {};
  final Map<String, int> _generations = {};
  final Map<String, Object?> _spans = {};
  final Set<String> _reported = {};

  UploadObserver? _observer;
  bool _open = false;
  bool _reconciling = false;
  Future<void>? _opening;

  /// When this engine last changed a status (null before the first change). Read through
  /// `package:clock`.
  DateTime? get lastChange => _lastChange;
  DateTime? _lastChange;

  /// Whether [open] has finished and [close] has not been called.
  bool get isOpen => _open;

  /// The status of every upload the engine knows, by id. A copy.
  Map<String, DownloadStatus> get statuses => Map.unmodifiable(_statuses);

  /// Where the upload [id] stands; [Absent] when it is unknown.
  DownloadStatus statusOf(String id) => _statuses[id] ?? const Absent();

  /// Whether the upload [id] ended without an answer and was not replay safe, so that the server
  /// may or may not have it: `Failed(network)`, `Failed(killed)` or `Failed(other)` of an upload
  /// without an `Idempotency-Key`. Ask the server before deciding to send it again.
  bool outcomeUnknown(String id) {
    final request = _requests[id];
    final current = _statuses[id];
    return request != null &&
        !request.replaySafe &&
        current is Failed &&
        _unknown.contains(current.failure);
  }

  static const Set<DownloadFailure> _unknown = {
    DownloadFailure.network,
    DownloadFailure.killed,
    DownloadFailure.other,
  };

  /// Sets the one owner of status changes, replacing any earlier one; null clears it.
  void observe(UploadObserver? onChange) {
    _observer = onChange;
  }

  /// Opens the backend and settles the registry with what it reports.
  ///
  /// Every entry of the store starts as [Queued] and the backend's replay moves it on. An entry
  /// the backend did not mention ends `Failed(killed)`, **never `Complete`**: the file that was
  /// sent is still there, so its presence says nothing about whether the server took it. Calling
  /// it twice does the work once.
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
      _apply(id, const Failed(DownloadFailure.killed), reconciled: true);
    }
    _reported.clear();
  }

  /// Unregisters from the backend, closes it and clears the observer. The transfers the platform
  /// owns go on. Calling it twice does nothing the second time.
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _opening = null;
    _observer = null;
    for (final token in _spans.values) {
      uploadFinish(token, const Cancelled());
    }
    _spans.clear();
    await _backend.close();
  }

  /// Starts the upload [request].
  ///
  /// An invalid request ends `Failed(invalidRequest)` and is not registered: it never throws. A
  /// `userInitiated` request on a backend with no notifications ends
  /// `Failed(notificationsRequired)`. Starting an id that is already running or complete does
  /// nothing: it is the same upload. **Starting an id whose last attempt may have reached the
  /// server and that is not replay safe does nothing either** (see [outcomeUnknown]): [remove]
  /// it first to send it again on purpose.
  Future<void> start(UploadRequest request) async {
    if (!_open) throw StateError('Uploads.start before open()');
    final id = request.id;
    if (!request.isValid) {
      _failEarly(id, DownloadFailure.invalidRequest);
      return;
    }
    final current = statusOf(id);
    if (_isActive(current) || current is Complete) return;
    if (current is Failed && !_mayResend(id)) return;
    if (request.priority == DownloadPriority.userInitiated &&
        !_backend.capabilities.notifications) {
      _failEarly(id, DownloadFailure.notificationsRequired);
      return;
    }
    await _begin(request);
  }

  /// Sends a failed upload [id] again from its registered request. True when it was started.
  ///
  /// Only a replay-safe upload is sent again; one without an `Idempotency-Key` is sent again only
  /// when it failed before the server could have it (`unauthorized`, `rejected`, `storage`,
  /// `invalidRequest`, `unsupported`, `notificationsRequired`), never after [outcomeUnknown].
  Future<bool> retry(String id) async {
    final current = statusOf(id);
    final request = _requests[id];
    if (current is! Failed || request == null || !_mayResend(id)) return false;
    if (current.failure == DownloadFailure.notificationsRequired &&
        !_backend.capabilities.notifications &&
        request.priority == DownloadPriority.userInitiated) {
      return false;
    }
    final generation = _bump(id);
    await _backend.cancel(id);
    if (generation != _generationOf(id)) return false;
    await _begin(request, bumped: true);
    return true;
  }

  /// Stops the upload [id] for good and drops it from the registry. A finished upload is not
  /// touched (use [remove]). The status becomes [Cancelled]. The file is never deleted.
  Future<void> cancel(String id) async {
    final request = _requests[id];
    final current = statusOf(id);
    if (request == null || current is Complete) return;
    final generation = _bump(id);
    _requests.remove(id);
    _regranted.remove(id);
    _apply(id, const Cancelled());
    await _backend.cancel(id);
    if (generation != _generationOf(id)) return;
    await _store.remove(id);
  }

  /// Forgets the upload [id]: stops it and drops it from the registry. The status becomes
  /// [Absent]. The file is never deleted.
  Future<void> remove(String id) async {
    if (!_requests.containsKey(id) && !_statuses.containsKey(id)) return;
    final generation = _bump(id);
    _requests.remove(id);
    _regranted.remove(id);
    uploadFinish(_spans.remove(id), const Cancelled());
    if (_statuses.remove(id) != null) _notify(id, const Absent());
    await _backend.cancel(id);
    if (generation != _generationOf(id)) return;
    await _store.remove(id);
  }

  /// Sign-out: cancels every upload and drops the registry, and moves every generation on so that
  /// nothing an earlier attempt was going to do, and no later event, reaches the next account.
  /// The files are not touched.
  Future<void> clearAccount() async {
    final stored = await _store.load();
    for (final id in {
      ..._generations.keys,
      ...stored.keys,
      ..._requests.keys,
    }) {
      _bump(id);
    }
    final known = _statuses.keys.toList();
    for (final token in _spans.values) {
      uploadFinish(token, const Cancelled());
    }
    _spans.clear();
    _requests.clear();
    _regranted.clear();
    _statuses.clear();
    _reported.clear();
    for (final id in known) {
      _notify(id, const Absent());
    }
    await _backend.cancelAll();
    await _store.clear();
  }

  bool _mayResend(String id) {
    final request = _requests[id];
    if (request == null || request.replaySafe) return true;
    final current = _statuses[id];
    return !(current is Failed && _unknown.contains(current.failure));
  }

  bool _isActive(DownloadStatus s) =>
      s is Queued || s is Waiting || s is Running || s is Verifying;

  int _generationOf(String id) => _generations[id] ?? 0;

  int _bump(String id) => _generations[id] = _generationOf(id) + 1;

  void _failEarly(String id, DownloadFailure failure) {
    _bump(id);
    _apply(id, Failed(failure));
  }

  Future<void> _begin(UploadRequest request, {bool bumped = false}) async {
    final id = request.id;
    final generation = bumped ? _generationOf(id) : _bump(id);
    _requests[id] = request;
    _spans.remove(id);
    _spans[id] = uploadBegin(
      request,
      background: _backend.capabilities.background,
    );
    _apply(id, const Queued());
    _regranted.remove(id);
    await _store.put(StoredUpload(request, generation: generation));
    if (generation != _generationOf(id)) return;
    final granted = await _ask(id, request, generation, renewal: false);
    if (granted == null) return;
    final accepted = await _backend.enqueue(
      granted.request,
      authorization: granted.headers,
    );
    if (generation != _generationOf(id)) return;
    if (!accepted) _apply(id, const Failed(DownloadFailure.other));
  }

  // Null means the attempt is over: a newer one owns the id, or the grant failed and the upload
  // ended Failed(unauthorized). The grant is used for this attempt and kept nowhere.
  Future<_Granted?> _ask(
    String id,
    UploadRequest request,
    int generation, {
    required bool renewal,
  }) async {
    final grantor = _grantor;
    if (grantor == null) return _Granted(request, const {});
    DownloadGrant? grant;
    try {
      grant = await grantor(request, renewal: renewal);
    } catch (_) {
      // Nothing of the error is kept: it may name the account or the file.
      if (generation == _generationOf(id)) {
        _apply(id, const Failed(DownloadFailure.unauthorized));
      }
      return null;
    }
    if (generation != _generationOf(id)) return null;
    if (grant == null) return _Granted(request, const {});
    final granted = grant.url;
    final sent = granted == null ? request : request.withUrl(granted);
    if (!sent.isValid) {
      _apply(id, const Failed(DownloadFailure.unauthorized));
      return null;
    }
    return _Granted(sent, Map.of(grant.headers));
  }

  // The one renewal, for a replay-safe upload only: the failed attempt is cancelled and the
  // upload is enqueued again with a new grant.
  Future<void> _regrant(String id, UploadRequest request) async {
    _regranted.add(id);
    final generation = _bump(id);
    _apply(id, const Queued());
    try {
      final granted = await _ask(id, request, generation, renewal: true);
      if (granted == null) return;
      await _backend.cancel(id);
      if (generation != _generationOf(id)) return;
      final accepted = await _backend.enqueue(
        granted.request,
        authorization: granted.headers,
      );
      if (generation != _generationOf(id)) return;
      if (!accepted) _apply(id, const Failed(DownloadFailure.other));
    } catch (_) {
      if (generation == _generationOf(id)) {
        _apply(id, const Failed(DownloadFailure.other));
      }
    }
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
      final request = _requests[id];
      if (_grantor != null &&
          request != null &&
          request.replaySafe &&
          !_reconciling &&
          !_regranted.contains(id)) {
        unawaited(_regrant(id, request));
        return;
      }
      next = const Failed(DownloadFailure.unauthorized);
    }
    // An upload cannot pause: a backend that says so is wrong, and it is not shown.
    if (next is Absent || next is Paused) return;
    if (next is Cancelled) {
      cancel(id).then<void>((_) {}, onError: (Object _) {});
      return;
    }
    _apply(id, next, reconciled: _reconciling);
  }

  void _apply(String id, DownloadStatus status, {bool reconciled = false}) {
    if (_statuses[id] == status) return;
    _statuses[id] = status;
    _lastChange = (_clock ?? time.clock).now();
    final terminal =
        status is Complete || status is Failed || status is Cancelled;
    if (terminal) {
      final span = _spans.remove(id);
      final regranted = _regranted.remove(id);
      if (span != null) {
        uploadFinish(span, status, regranted: regranted);
      } else if (reconciled && status is! Cancelled) {
        uploadReconciledReport(status);
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
      // An observer that throws costs its own update, never the upload.
    }
  }
}

final class _Events implements UploadEvents {
  _Events(this._engine);

  final Uploads _engine;

  @override
  void status(String id, DownloadStatus status, {int? httpStatus}) =>
      _engine._onStatus(id, status, httpStatus);
}

final class _Granted {
  const _Granted(this.request, this.headers);

  final UploadRequest request;
  final Map<String, String> headers;
}
