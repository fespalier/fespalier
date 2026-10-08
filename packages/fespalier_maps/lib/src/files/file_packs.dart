import 'dart:async';

import 'package:fespalier/fespalier.dart'
    show Notifier, NotifierProvider, Provider, TelemetryOutcome;
import 'package:http/http.dart' as http;

import '../offline/status.dart';
import '../offline/tile_packs.dart' show StorageUse;
import '../telemetry.dart';
import 'request.dart';
import 'store.dart';
import 'store_stub.dart' if (dart.library.io) 'store_io.dart';

/// The HTTP client file packs download with. It has **no default**: the app overrides it with
/// the client it already has (one with its own timeouts, certificates and proxy), and a test with
/// a `MockClient`. `FilePacks` never closes it.
final Provider<http.Client> packHttpClient = Provider<http.Client>(
  (ref) => throw StateError(
    'packHttpClient has no default: override it in the ProviderScope with the app\'s '
    'http.Client, or a MockClient in a test.',
  ),
);

/// The files file packs write. The default is the `dart:io` store (on the web it answers
/// `UnsupportedError`, so a download ends in `Failed(unsupported)`); a test overrides it with a
/// `FakePackFiles`.
final Provider<PackFileStore> packFileStore = Provider<PackFileStore>(
  (ref) => defaultPackFileStore(),
);

/// The file packs by key, and what each is doing (since 0.13.0). Watch it, or one pack:
///
/// ```dart
/// final status = ref.watch(filePackStatus('douala')); // a PackStatus
/// ref.read(filePacks.notifier).start(request);
/// ```
final NotifierProvider<FilePacks, Map<String, PackStatus>> filePacks =
    NotifierProvider<FilePacks, Map<String, PackStatus>>(FilePacks.new);

/// The status of one file pack: [Absent] while there is none. It rebuilds only when that pack's
/// status changes.
final filePackStatus = Provider.autoDispose.family<PackStatus, String>(
  (ref, key) => ref.watch(filePacks)[key] ?? const Absent(),
);

final RegExp _contentRange = RegExp(
  r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
  caseSensitive: false,
);
final RegExp _unsatisfied = RegExp(r'^bytes\s+\*/(\d+)$', caseSensitive: false);

/// How far one transfer is told about: at least this many bytes, or a 200th of the file.
const int _reportStep = 64 * 1024;

enum _Step { verify, stop, restart }

final class _Run {
  final Completer<void> done = Completer<void>();

  // Completes to abort the request in flight (a pause, a removal, the end of the provider): a
  // connection that sends nothing cannot hold them up.
  final Completer<void> abort = Completer<void>();

  void stop() {
    if (!abort.isCompleted) abort.complete();
  }
}

// The body of a response and whether the transfer took it: a body nobody reads is cancelled.
final class _Body {
  _Body(this.response);

  final http.StreamedResponse response;
  bool taken = false;
}

// Cancels a response body that is not wanted (an error status, a restart) after its first event,
// without waiting for the rest. No `listen` here: `await for` is the subscription.
Future<void> _abandon(http.StreamedResponse response) async {
  try {
    await for (final _ in response.stream) {
      break;
    }
  } catch (_) {
    // The connection is being thrown away anyway.
  }
}

/// The file packs of the app: one file each, downloaded over HTTP with `Range` requests so that
/// a transfer continues where it stopped, **after a pause, after an error and after the app was
/// closed** (since 0.13.0). State is one [PackStatus] per key, the same values region packs use.
///
/// Where the bytes are: they arrive in `<destination>.part`, with the server's validator beside
/// it (`.part.etag`). A transfer that stops leaves them. The next attempt asks for
/// `Range: bytes=<size of the partial file>-` (and `If-Range` with the validator, so a file that
/// changed on the server is fetched again whole) and appends what comes. The file is moved to its
/// destination only when it is the size and the SHA-256 the request names, so **a file at the
/// destination is always a whole, checked one**, and a partial file whose check fails is deleted.
/// A server that ignores `Range` (it answers 200) makes the transfer start again from the first
/// byte; one that answers 416 to a partial file the server no longer has the end of gets one
/// restart too.
///
/// It starts no timer and listens to nothing: the response body is read with `await for`, which
/// ends when the transfer stops, is paused or removed. [pause] stops the transfer at the next
/// chunk and keeps the partial file; [resume] is a new request with a new `Range`.
///
/// **Nothing is read at start.** Disk is the state of record: call [refresh] with the app's
/// requests once (at startup, or when a packs page opens) to learn which packs are `Complete` and
/// which are `Interrupted` with a partial file. The registry of what packs exist is the app's:
/// this class cannot find a pack on disk without its request.
///
/// On the web a file pack ends in `Failed(PackFailure.unsupported)` before any request is made.
///
/// Telemetry (see `MapsTelemetry.download`, kind `file`) carries constants only: never the URL,
/// the paths, the key or the hash.
class FilePacks extends Notifier<Map<String, PackStatus>> {
  late PackFileStore _files;

  // Per key: the definition, for resuming and for deleting its files.
  final Map<String, FilePackRequest> _requests = {};
  // Per key: bumped by every start and removal and never reset, so a transfer that is over (or
  // was replaced) cannot change the state.
  final Map<String, int> _generation = {};
  // Per key: the running transfer.
  final Map<String, _Run> _runs = {};
  // Keys being removed: a start of one takes the key over.
  final Set<String> _removing = {};
  // Keys whose running transfer was asked to pause.
  final Set<String> _pausing = {};
  // Per key: the telemetry operation of the running download.
  final Map<String, Object?> _spans = {};

  @override
  Map<String, PackStatus> build() {
    _files = ref.read(packFileStore);
    ref.onDispose(() {
      // The transfers are aborted, see the unmounted notifier and close their files.
      for (final run in _runs.values) {
        run.stop();
      }
      for (final token in _spans.values) {
        mapsFinish(
          token,
          MapsTelemetry.resultCancelled,
          outcome: TelemetryOutcome.superseded,
        );
      }
      _spans.clear();
    });
    return const {};
  }

  void _set(String key, PackStatus status) {
    if (!ref.mounted) return;
    state = {...state, key: status};
  }

  void _clear(String key) {
    if (!ref.mounted || !state.containsKey(key)) return;
    state = {...state}..remove(key);
  }

  int _bump(String key) => _generation[key] = (_generation[key] ?? 0) + 1;

  bool _current(String key, int generation) =>
      ref.mounted && _generation[key] == generation;

  static bool _isActive(PackStatus? status) =>
      status is Downloading || status is Paused;

  void _endSpan(String key, String result, {String? outcome}) {
    final token = _spans.remove(key);
    mapsFinish(token, result, outcome: outcome ?? TelemetryOutcome.ok);
  }

  void _fail(String key, PackFailure reason) {
    _endSpan(key, MapsTelemetry.resultFailed, outcome: TelemetryOutcome.error);
    _set(key, Failed(reason));
  }

  static PackFailure _storeFailure(Object error) =>
      error is UnsupportedError ? PackFailure.unsupported : PackFailure.storage;

  /// Downloads [request], continuing a partial file of an earlier attempt. Does nothing while a
  /// download of the same key is running or paused. A pack whose file is already at the
  /// destination (with the size the request names) becomes [Complete] without a request: to get a
  /// newer file, [remove] the pack first or give the new one another destination. A file of
  /// another size than the request names stays where it is until the new one is whole and checked,
  /// and is then replaced by the move.
  ///
  /// An invalid request (see [FilePackRequest.isValid]), or one whose destination another key
  /// uses, ends in [Failed] with [PackFailure.invalidRequest], and nothing is read or sent.
  ///
  /// **Completes when the transfer stops**: with the pack [Complete], [Failed], [Paused] (see
  /// [pause]) or removed. Never throws for a failure of the transfer; when [packHttpClient] was
  /// not overridden it throws the `ProviderException` Riverpod wraps the explaining `StateError`
  /// in. Do not `await` it in a button handler that has to stay responsive; the state is what
  /// the page watches.
  Future<void> start(FilePackRequest request) async {
    if (_isActive(state[request.key]) && !_removing.contains(request.key)) {
      return;
    }
    await _begin(request);
  }

  Future<void> _begin(FilePackRequest request) async {
    final key = request.key;
    final client = ref.read(packHttpClient);
    if (!request.isValid) {
      if (key.isNotEmpty) _set(key, const Failed(PackFailure.invalidRequest));
      return;
    }
    for (final entry in _requests.entries) {
      if (entry.key != key &&
          entry.value.destination == request.destination &&
          state[entry.key] != null) {
        _set(key, const Failed(PackFailure.invalidRequest));
        return;
      }
    }
    // A pack that was paused is the same download going on: its operation stays open.
    final continuing = state[key] is Paused && _spans.containsKey(key);
    final generation = _bump(key);
    _pausing.remove(key);
    _removing.remove(key);
    _requests[key] = request;
    if (!continuing) {
      _endSpan(
        key,
        MapsTelemetry.resultCancelled,
        outcome: TelemetryOutcome.superseded,
      );
      _spans[key] = mapsBegin(MapsTelemetry.download, {
        MapsTelemetry.kind: MapsTelemetry.kindFile,
      });
    }
    final previous = state[key];
    _set(
      key,
      Downloading(
        progress: previous is Paused ? previous.progress : 0,
        bytes: previous is Paused ? previous.bytes : 0,
      ),
    );
    final earlier = _runs[key];
    final run = _Run();
    _runs[key] = run;
    try {
      // An earlier transfer of this key (a removal is still stopping it) closes its file first:
      // two never write the same one.
      if (earlier != null) await earlier.done.future;
      if (!_current(key, generation)) return;
      await _work(request, generation, client);
    } catch (error) {
      if (_current(key, generation)) {
        _fail(
          key,
          error is UnsupportedError
              ? PackFailure.unsupported
              : PackFailure.other,
        );
      }
    } finally {
      if (_current(key, generation)) _pausing.remove(key);
      if (identical(_runs[key], run)) _runs.remove(key);
      run.done.complete();
    }
  }

  Future<void> _work(
    FilePackRequest r,
    int generation,
    http.Client client,
  ) async {
    final key = r.key;
    var offset = 0;
    try {
      final done = await _files.length(r.destination);
      if (!_current(key, generation)) return;
      if (done != null) {
        if (r.bytes == null || done == r.bytes) {
          _endSpan(key, MapsTelemetry.resultComplete);
          _set(key, Complete(bytes: done));
          return;
        }
        // The file of another size stays: the move at the end replaces it atomically.
      }
      offset = await _files.length(r.partial) ?? 0;
    } catch (error) {
      if (_current(key, generation)) _fail(key, _storeFailure(error));
      return;
    }
    if (!_current(key, generation)) return;
    var restarted = false;
    while (true) {
      try {
        if (offset > 0 && r.bytes != null && offset > r.bytes!) {
          await _dropPartial(r);
          offset = 0;
        }
      } catch (error) {
        if (_current(key, generation)) _fail(key, _storeFailure(error));
        return;
      }
      final step = await _fetch(r, generation, client, offset);
      if (!_current(key, generation)) return;
      switch (step) {
        case _Step.stop:
          return;
        case _Step.verify:
          await _verify(r, generation);
          return;
        case _Step.restart:
          if (restarted) {
            _fail(key, PackFailure.rejected);
            return;
          }
          restarted = true;
          try {
            await _dropPartial(r);
          } catch (error) {
            if (_current(key, generation)) _fail(key, _storeFailure(error));
            return;
          }
          offset = 0;
      }
    }
  }

  Future<void> _dropPartial(FilePackRequest r) async {
    await _files.delete(r.partial);
    await _files.delete(r.validator);
  }

  /// One request, from [offset]: the partial file is appended to, or emptied when the server
  /// sent the whole body.
  Future<_Step> _fetch(
    FilePackRequest r,
    int generation,
    http.Client client,
    int offset,
  ) async {
    final key = r.key;
    if (r.bytes != null && offset == r.bytes) return _Step.verify;
    String? validator;
    if (offset > 0) {
      try {
        validator = await _files.readText(r.validator);
      } catch (error) {
        if (_current(key, generation)) _fail(key, _storeFailure(error));
        return _Step.stop;
      }
      // Without a validator nothing says the partial file belongs to the file the server has
      // now: only a hash (checked at the end) makes a blind continuation safe. Otherwise the
      // transfer starts from the first byte and the partial file is emptied when it begins.
      if (validator == null && r.sha256 == null) offset = 0;
    }
    final run = _runs[key]!;
    final request = http.AbortableRequest(
      'GET',
      r.url,
      abortTrigger: run.abort.future,
    );
    request.headers.addAll(r.headers);
    request.headers.remove('range');
    request.headers.remove('if-range');
    // Offsets count the bytes on the wire: a compressed body would make them mean nothing.
    request.headers['accept-encoding'] = 'identity';
    if (offset > 0) {
      request.headers['range'] = 'bytes=$offset-';
      if (validator != null) request.headers['if-range'] = validator;
    }
    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (_) {
      if (!_current(key, generation)) return _Step.stop;
      if (_pausing.remove(key)) {
        _setPaused(key, offset, r.bytes);
      } else {
        _fail(key, PackFailure.network);
      }
      return _Step.stop;
    }
    final body = _Body(response);
    try {
      return await _handle(r, generation, offset, validator, body);
    } finally {
      if (!body.taken) unawaited(_abandon(response));
    }
  }

  Future<_Step> _handle(
    FilePackRequest r,
    int generation,
    int offset,
    String? validator,
    _Body body,
  ) async {
    final key = r.key;
    final response = body.response;
    if (!_current(key, generation)) return _Step.stop;
    if (_pausing.remove(key)) {
      _setPaused(key, offset, r.bytes);
      return _Step.stop;
    }

    var append = false;
    int? total;
    switch (response.statusCode) {
      case 416:
        final unsatisfied = _unsatisfied.firstMatch(
          response.headers['content-range'] ?? '',
        );
        final size = int.tryParse(unsatisfied?.group(1) ?? '');
        if (offset > 0 && size == offset) return _Step.verify;
        if (offset > 0) return _Step.restart;
        _fail(key, PackFailure.rejected);
        return _Step.stop;
      case 206:
        final range = _contentRange.firstMatch(
          response.headers['content-range'] ?? '',
        );
        if (range == null || int.parse(range.group(1)!) != offset) {
          return _Step.restart;
        }
        // A server or CDN that ignored If-Range may be sending another file's tail: the
        // validator of this answer must be the one the partial file was started with.
        if (offset > 0 &&
            validator != null &&
            _validatorOf(response.headers) != validator) {
          return _Step.restart;
        }
        total = int.tryParse(range.group(3)!);
        append = offset > 0;
      case 200:
        // The whole body: the server ignored Range, or If-Range said the file changed.
        final length = response.contentLength;
        total = length != null && length > 0 ? length : null;
        offset = 0;
      default:
        _fail(key, PackFailure.rejected);
        return _Step.stop;
    }
    if (r.bytes != null && total != null && total != r.bytes) {
      try {
        await _dropPartial(r);
      } catch (_) {
        // The failure below is what the app learns.
      }
      if (_current(key, generation)) _fail(key, PackFailure.sizeMismatch);
      return _Step.stop;
    }
    final expected = r.bytes ?? total;

    var received = offset;
    PackFailure? failure;
    var paused = false;
    PackFileSink? sink;
    try {
      // A new file starts: the old validator goes first, so a crash leaves no validator that
      // belongs to bytes of another file.
      if (!append) await _files.delete(r.validator);
      sink = await _files.open(r.partial, append: append);
      if (!append) {
        final tag = _validatorOf(response.headers);
        if (tag != null) await _files.writeText(r.validator, tag);
      }
    } catch (error) {
      failure = _storeFailure(error);
    }
    if (failure == null && _current(key, generation)) {
      body.taken = true;
      _set(
        key,
        Downloading(progress: _fraction(received, expected), bytes: received),
      );
      var reported = received;
      final step = expected == null ? _reportStep : expected ~/ 200;
      try {
        await for (final chunk in response.stream) {
          if (!_current(key, generation)) break;
          try {
            await sink!.add(chunk);
          } catch (error) {
            failure = _storeFailure(error);
            break;
          }
          received += chunk.length;
          if (!_current(key, generation)) break;
          if (_pausing.contains(key)) {
            paused = true;
            break;
          }
          if (received - reported >=
              (step < _reportStep ? _reportStep : step)) {
            reported = received;
            _set(
              key,
              Downloading(
                progress: _fraction(received, expected),
                bytes: received,
              ),
            );
          }
        }
      } catch (_) {
        failure ??= PackFailure.network;
      }
    }
    try {
      await sink?.close();
    } catch (error) {
      failure ??= _storeFailure(error);
    }
    // A pause aborts the request: the error that reads as a broken connection is a pause.
    if (_pausing.contains(key) && failure == PackFailure.network) {
      failure = null;
      paused = true;
    }
    if (!_current(key, generation)) return _Step.stop;
    if (paused) {
      _pausing.remove(key);
      _setPaused(key, received, expected);
      return _Step.stop;
    }
    if (failure != null) {
      _fail(key, failure);
      return _Step.stop;
    }
    if (expected != null && received != expected) {
      if (received < expected) {
        // The body ended short without an error: the connection is what failed.
        _fail(key, PackFailure.network);
      } else {
        try {
          await _dropPartial(r);
        } catch (_) {
          // The failure below is what the app learns.
        }
        if (_current(key, generation)) _fail(key, PackFailure.sizeMismatch);
      }
      return _Step.stop;
    }
    return _Step.verify;
  }

  void _setPaused(String key, int received, int? expected) => _set(
    key,
    Paused(progress: _fraction(received, expected), bytes: received),
  );

  static double _fraction(int received, int? expected) =>
      expected == null || expected <= 0
      ? 0
      : (received / expected).clamp(0.0, 1.0);

  /// The `ETag` of a response (a strong one) or else its `Last-Modified`: what `If-Range` sends
  /// back. Null when the server gave neither.
  static String? _validatorOf(Map<String, String> headers) {
    final etag = headers['etag'];
    if (etag != null && etag.isNotEmpty && !etag.startsWith('W/')) return etag;
    final modified = headers['last-modified'];
    return modified != null && modified.isNotEmpty ? modified : null;
  }

  /// The partial file is whole: check it, then move it to its destination.
  Future<void> _verify(FilePackRequest r, int generation) async {
    final key = r.key;
    try {
      final size = await _files.length(r.partial);
      if (!_current(key, generation)) return;
      if (size == null || (r.bytes != null && size != r.bytes)) {
        await _dropPartial(r);
        if (_current(key, generation)) _fail(key, PackFailure.sizeMismatch);
        return;
      }
      final hash = r.sha256;
      if (hash != null) {
        final actual = await _files.sha256(r.partial);
        if (!_current(key, generation)) return;
        if (actual != hash.toLowerCase()) {
          await _dropPartial(r);
          if (_current(key, generation)) _fail(key, PackFailure.hashMismatch);
          return;
        }
      }
      await _files.rename(r.partial, r.destination);
      try {
        await _files.delete(r.validator);
      } catch (_) {
        // A leftover validator is harmless: the next partial file overwrites it.
      }
      if (!_current(key, generation)) return;
      _endSpan(key, MapsTelemetry.resultComplete);
      _set(key, Complete(bytes: size));
    } catch (error) {
      if (_current(key, generation)) _fail(key, _storeFailure(error));
    }
  }

  /// Pauses a running transfer: the request is aborted (so a connection that sends nothing cannot
  /// hold it), the partial file is kept, and the pack becomes [Paused]. Completes when the transfer has stopped. Does nothing when the pack is not
  /// [Downloading]. A transfer that is already checking its file finishes instead.
  Future<void> pause(String key) async {
    if (state[key] is! Downloading) return;
    final run = _runs[key];
    if (run == null) return;
    _pausing.add(key);
    run.stop();
    await run.done.future;
  }

  /// Resumes a pack: a [Paused], [Interrupted] or [Failed] one asks the server for the bytes the
  /// partial file lacks (`Range`), so **the transfer goes on from where it stopped**, in this
  /// session or after a restart ([refresh] first). Completes when that transfer stops. Anything
  /// else does nothing. A pack the notifier has no request for (not [start]ed or [refresh]ed
  /// this session) does nothing.
  Future<void> resume(String key) async {
    final status = state[key];
    if (status is! Paused && status is! Interrupted && status is! Failed) {
      return;
    }
    final request = _requests[key];
    if (request == null) return;
    await _begin(request);
  }

  /// Deletes a pack: stops its transfer if one runs, then deletes the finished file, the partial
  /// file and the validator, and forgets the pack. When a file cannot be deleted the pack becomes
  /// [Failed] with [PackFailure.other] (as a region pack does) and the error is rethrown. A [start] of the same key while
  /// this runs takes the key over. A pack this notifier has no request for has no files it can
  /// name: [refresh] with its request first.
  Future<void> remove(String key) async {
    final generation = _bump(key);
    _pausing.remove(key);
    _removing.add(key);
    _endSpan(
      key,
      MapsTelemetry.resultCancelled,
      outcome: TelemetryOutcome.superseded,
    );
    final run = _runs[key];
    // The request is aborted; the transfer closes its file before the files are deleted.
    run?.stop();
    if (run != null) await run.done.future;
    if (_generation[key] != generation) return;
    final request = _requests[key];
    Object? failure;
    if (request != null) {
      for (final path in [
        request.partial,
        request.validator,
        request.destination,
      ]) {
        try {
          await _files.delete(path);
        } catch (error) {
          failure ??= error;
        }
      }
    }
    if (_generation[key] != generation) return;
    _removing.remove(key);
    if (failure != null) {
      _set(key, const Failed(PackFailure.other));
      throw failure;
    }
    _requests.remove(key);
    _clear(key);
  }

  /// Reads the disk for each of [requests] and updates every pack this session is not
  /// downloading: a file at the destination (of the size the request names) is [Complete], a
  /// partial file is [Interrupted] (its bytes and, when the request names a size, its progress),
  /// and neither leaves the state empty for that key. It also remembers each request, so
  /// [resume] and [remove] can act on a pack of an earlier session.
  ///
  /// A file at the destination is trusted: it was moved there only after its checks. A request
  /// that is not valid is skipped.
  Future<void> refresh(Iterable<FilePackRequest> requests) async {
    for (final request in requests) {
      if (!request.isValid) continue;
      final key = request.key;
      if (_isActive(state[key])) continue;
      final generation = _generation[key] ?? 0;
      int? done;
      int? part;
      try {
        done = await _files.length(request.destination);
        part = await _files.length(request.partial);
      } catch (error) {
        if (_isActive(state[key]) || (_generation[key] ?? 0) != generation) {
          continue;
        }
        if (error is UnsupportedError) {
          _set(key, const Failed(PackFailure.unsupported));
        }
        continue;
      }
      if (!ref.mounted ||
          _isActive(state[key]) ||
          (_generation[key] ?? 0) != generation) {
        continue;
      }
      _requests[key] = request;
      if (done != null && (request.bytes == null || done == request.bytes)) {
        _set(key, Complete(bytes: done));
      } else if (part != null) {
        _set(
          key,
          Interrupted(progress: _fraction(part, request.bytes), bytes: part),
        );
      } else {
        _clear(key);
      }
    }
  }

  /// What the packs take: the bytes of each (from the state, which [refresh] fills for packs of
  /// earlier sessions) and, as [StorageUse.onDisk], the sum of the files the notifier knows
  /// (finished and partial). File packs do not overlap, so unlike region packs the rows add up
  /// to it. Null when the store cannot tell (the web).
  Future<StorageUse> storage() async {
    final perPack = <String, int>{};
    for (final entry in state.entries) {
      final bytes = switch (entry.value) {
        Downloading(:final bytes) => bytes,
        Paused(:final bytes) => bytes,
        Complete(:final bytes) => bytes,
        Interrupted(:final bytes) => bytes,
        Absent() || Failed() => null,
      };
      if (bytes != null) perPack[entry.key] = bytes;
    }
    int? onDisk = 0;
    try {
      for (final request in _requests.values) {
        onDisk =
            onDisk! +
            (await _files.length(request.destination) ?? 0) +
            (await _files.length(request.partial) ?? 0);
      }
    } catch (_) {
      onDisk = null;
    }
    return StorageUse(perPack: perPack, onDisk: onDisk);
  }
}
