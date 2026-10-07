import 'dart:async';

import 'package:fespalier/fespalier.dart'
    show Notifier, NotifierProvider, Provider, TelemetryOutcome;
import 'package:flutter/foundation.dart';

import '../telemetry.dart';
import 'port.dart';
import 'request.dart';
import 'status.dart';

/// The offline database `TilePacks` drives. It has no default: the app overrides it with
/// `MapLibreOfflineTiles()` (`package:fespalier_maps/maplibre.dart`), and a test with a
/// `FakeOfflineTiles`.
final Provider<OfflineTiles> offlineTiles = Provider<OfflineTiles>(
  (ref) => throw StateError(
    'offlineTiles has no default: override it in the ProviderScope with '
    'MapLibreOfflineTiles() (package:fespalier_maps/maplibre.dart), or a FakeOfflineTiles '
    'in a test.',
  ),
);

/// The packs by key, and what each is doing (since 0.13.0). Watch it, or one pack:
///
/// ```dart
/// final status = ref.watch(tilePackStatus('douala')); // a PackStatus
/// await ref.read(tilePacks.notifier).start(request);
/// ```
final NotifierProvider<TilePacks, Map<String, PackStatus>> tilePacks =
    NotifierProvider<TilePacks, Map<String, PackStatus>>(TilePacks.new);

/// The status of one pack: [Absent] while there is none. It rebuilds only when that pack's
/// status changes.
final tilePackStatus = Provider.autoDispose.family<PackStatus, String>(
  (ref, key) => ref.watch(tilePacks)[key] ?? const Absent(),
);

/// How much room the packs take.
@immutable
final class StorageUse {
  /// A use of [perPack] bytes per key, in a database of [onDisk] bytes.
  const StorageUse({required this.perPack, this.onDisk});

  /// The bytes each pack's resources take, from MapLibre's status of its region. A resource two
  /// packs share (a glyph range, a tile on the edge of both) is counted in each, so the sum can
  /// be more than [onDisk].
  final Map<String, int> perPack;

  /// The size of the whole offline database file, which also holds MapLibre's ambient cache; null
  /// when the port could not tell.
  final int? onDisk;

  /// The sum of [perPack]: an upper bound of what the packs add, not what they take.
  int get packSum => perPack.values.fold(0, (a, b) => a + b);
}

/// The offline region packs of the app: download with progress, pause, resume, delete, and what
/// they take (since 0.13.0). State is one [PackStatus] per key; a key with no status is absent.
///
/// It starts no timer and listens to nothing: MapLibre reports a download through a callback this
/// class hands it, and the app watches [tilePacks]. Nothing is read at start: call [refresh]
/// once (at startup, or when a packs page opens) to learn what an earlier session stored.
///
/// **A download does not survive the app's end.** MapLibre keeps the tiles it stored, but the
/// download itself stops, and the next session finds the region [Interrupted]; [resume] of an
/// interrupted pack starts the same definition again (it may fetch resources it already has).
/// Pause and resume of a running download work within the session only.
///
/// **MapLibre treats two regions with the same style, rectangle and zoom range as one**
/// (`maplibre_gl` 0.27): downloading a definition deletes the region that already has it, at the
/// start, and on iOS the new region takes the old one's id. So starting a pack again (a resume
/// of an interrupted or failed one, or a `start` of a complete one) removes the old region when
/// the download begins, and a download that then fails has lost the old pack. And two keys
/// cannot share a definition: [start] refuses the second with [PackFailure.duplicateRegion].
///
/// If the provider is invalidated while a download runs, the state starts empty and the events of
/// that download are dropped until [refresh] reads the database again (it then shows the pack as
/// [Interrupted] or [Complete]); the platform keeps downloading meanwhile.
class TilePacks extends Notifier<Map<String, PackStatus>> {
  late OfflineTiles _tiles;

  // Per key: the id of the region the running (or last) download made.
  final Map<String, int> _ids = {};
  // Per key: ids of older regions of the same key, deleted when a newer download completes.
  final Map<String, Set<int>> _older = {};
  // Per key: the definition, for starting it again and for refusing a duplicate.
  final Map<String, RegionPackRequest> _requests = {};
  // Per key: bumped by every start and removal and never reset, so an event or an answer of a
  // download that is over is dropped.
  final Map<String, int> _generation = {};
  // Keys with a started pack that is not being removed.
  final Set<String> _live = {};
  // Per key: the telemetry operation of the running download.
  final Map<String, Object?> _spans = {};

  @override
  Map<String, PackStatus> build() {
    // Read, not watched: the database is the app's one, and a rebuild would forget the ids of
    // downloads that go on in the platform.
    _tiles = ref.read(offlineTiles);
    ref.onDispose(() {
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

  bool _isActive(PackStatus? status) =>
      status is Downloading || status is Paused;

  void _endSpan(String key, String result, {String? outcome}) {
    final token = _spans.remove(key);
    mapsFinish(token, result, outcome: outcome ?? TelemetryOutcome.ok);
  }

  // Whether a pack in this state may have a region in the database. A failure that comes before
  // or removes the region leaves none, so it does not block another key's definition.
  static bool _holdsRegion(PackStatus? status) => switch (status) {
    null || Absent() => false,
    Failed(:final reason) => reason == PackFailure.other,
    _ => true,
  };

  static bool _sameDefinition(RegionPackRequest a, RegionPackRequest b) =>
      a.bounds == b.bounds &&
      a.styleUrl == b.styleUrl &&
      a.minZoom == b.minZoom &&
      a.maxZoom == b.maxZoom;

  /// Downloads [request]. Does nothing while a download of the same key is running or paused;
  /// a complete pack is downloaded again, which replaces its region (see the class comment).
  /// A request that is not [RegionPackRequest.isValid] ends in [Failed] with
  /// [PackFailure.invalidRegion], and one whose definition another key already has ends in
  /// [PackFailure.duplicateRegion]; nothing reaches MapLibre in either case.
  ///
  /// Call [refresh] before the first [start] of a session: the duplicate refusal only sees the
  /// packs this notifier knows, and a pack of an earlier session is known after a refresh. A key
  /// whose pack failed without leaving a region (`limitExceeded`, `invalidRegion`,
  /// `duplicateRegion`, `unsupported`, `replaced`) does not block another key's definition.
  ///
  /// Completes when MapLibre has accepted the region, not when the download ends: the end is
  /// [Complete] or [Failed] in [state].
  Future<void> start(RegionPackRequest request) async {
    if (_isActive(state[request.key])) return;
    await _begin(request);
  }

  Future<void> _begin(RegionPackRequest request) async {
    final key = request.key;
    if (!request.isValid) {
      if (key.isNotEmpty) _set(key, const Failed(PackFailure.invalidRegion));
      return;
    }
    for (final entry in _requests.entries) {
      if (entry.key != key &&
          _holdsRegion(state[entry.key]) &&
          _sameDefinition(entry.value, request)) {
        _set(key, const Failed(PackFailure.duplicateRegion));
        return;
      }
    }
    final generation = _bump(key);
    _live.add(key);
    final previous = _ids.remove(key);
    if (previous != null) (_older[key] ??= {}).add(previous);
    _requests[key] = request;
    _endSpan(
      key,
      MapsTelemetry.resultCancelled,
      outcome: TelemetryOutcome.superseded,
    );
    _spans[key] = mapsBegin(MapsTelemetry.download, {
      MapsTelemetry.kind: MapsTelemetry.kindRegion,
    });
    _set(key, const Downloading());
    final StoredRegion region;
    try {
      region = await _tiles.download(
        request,
        (event) => _onEvent(key, generation, event),
      );
    } catch (error) {
      if (!_current(key, generation)) return;
      _endSpan(
        key,
        MapsTelemetry.resultFailed,
        outcome: TelemetryOutcome.error,
      );
      _set(key, Failed(PackFailure.of(error)));
      return;
    }
    if (!_current(key, generation)) {
      // Removed meanwhile: nobody owns the region just made. Started again meanwhile: the newer
      // download owns the key, and on iOS may even hold this very id.
      if (!_live.contains(key)) await _tryDelete(region.id);
      return;
    }
    // On iOS the new region takes the id of the one it replaced; on Android the plugin deleted
    // the old one before downloading. Either way it is not an older region to delete later.
    _older[key]?.remove(region.id);
    _ids[key] = region.id;
    if (state[key] is Complete) unawaited(_settle(key, generation));
  }

  void _onEvent(String key, int generation, DownloadEvent event) {
    if (!_current(key, generation)) return;
    final status = state[key];
    switch (event) {
      case DownloadProgress():
        if (status is! Downloading) return;
        _set(
          key,
          Downloading(
            progress: event.progress,
            completedResources: event.completedResources,
            requiredResources: event.requiredResources,
            bytes: event.bytes,
          ),
        );
      case DownloadFinished():
        if (!_isActive(status)) return;
        final bytes = switch (status) {
          Downloading(:final bytes) => bytes,
          Paused(:final bytes) => bytes,
          _ => 0,
        };
        _set(key, Complete(bytes: bytes));
        _endSpan(key, MapsTelemetry.resultComplete);
        if (_ids.containsKey(key)) unawaited(_settle(key, generation));
      case DownloadFailed():
        if (!_isActive(status)) return;
        _endSpan(
          key,
          MapsTelemetry.resultFailed,
          outcome: TelemetryOutcome.error,
        );
        _set(key, Failed(event.reason));
    }
  }

  /// After a pack completed: read its final size, and delete the older regions of the same key
  /// (never the one that just completed).
  Future<void> _settle(String key, int generation) async {
    final id = _ids[key];
    if (id == null) return;
    try {
      final status = await _tiles.status(id);
      if (_current(key, generation) && state[key] is Complete) {
        _set(key, Complete(bytes: status.bytes));
      }
    } catch (_) {
      // The size the events counted stays.
    }
    if (!_current(key, generation)) return;
    final older = _older.remove(key);
    if (older == null) return;
    for (final old in older) {
      if (old != id) await _tryDelete(old);
    }
  }

  Future<void> _tryDelete(int id) async {
    try {
      await _tiles.delete(id);
    } catch (_) {
      // A region that is already gone (MapLibre deletes the one a new download replaces).
    }
  }

  /// Pauses a running download. Works within the session only. Does nothing when the pack is not
  /// downloading, or when MapLibre refuses (the state stays [Downloading]).
  Future<void> pause(String key) async {
    final status = state[key];
    final id = _ids[key];
    final generation = _generation[key];
    if (status is! Downloading || id == null || generation == null) return;
    try {
      await _tiles.pause(id);
    } catch (_) {
      return;
    }
    if (!_current(key, generation)) return;
    final now = state[key];
    if (now is Downloading) {
      _set(key, Paused(progress: now.progress, bytes: now.bytes));
    }
  }

  /// Resumes a pack.
  ///
  /// - [Paused]: MapLibre continues the download in this session. If the native side has lost it
  ///   (it was restarted) the pack becomes [Interrupted] instead, and a second call restarts it.
  /// - [Interrupted] or [Failed]: the definition is downloaded **again**. MapLibre replaces the
  ///   old region at the start of that download (see the class comment); resources it already
  ///   stored may be reused or fetched again (not verified on a device). This is the restart, not
  ///   a resume from a byte offset.
  ///
  /// Anything else does nothing. Never throws.
  Future<void> resume(String key) async {
    final status = state[key];
    final generation = _generation[key];
    switch (status) {
      case Paused():
        final id = _ids[key];
        if (id == null || generation == null) return;
        try {
          await _tiles.resume(id);
        } catch (_) {
          if (_current(key, generation)) {
            _set(
              key,
              Interrupted(progress: status.progress, bytes: status.bytes),
            );
          }
          return;
        }
        if (_current(key, generation) && state[key] is Paused) {
          _set(
            key,
            Downloading(progress: status.progress, bytes: status.bytes),
          );
        }
      case Interrupted() || Failed():
        final request = _requests[key];
        if (request == null) return;
        await _begin(request);
      case Downloading() || Complete() || Absent() || null:
        return;
    }
  }

  /// Deletes a pack, stopping its download if it runs, and forgets it. Resources only this pack
  /// needed are freed by MapLibre. When MapLibre refuses, the pack becomes [Failed] with
  /// [PackFailure.other] and the error is rethrown. A [start] of the same key while this runs
  /// takes the key over: this call then cleans up nothing it does not own.
  Future<void> remove(String key) async {
    final generation = _bump(key);
    _live.remove(key);
    final ids = <int>{...?_older[key]};
    final current = _ids[key];
    if (current != null) ids.add(current);
    _endSpan(
      key,
      MapsTelemetry.resultCancelled,
      outcome: TelemetryOutcome.superseded,
    );
    Object? failure;
    for (final id in ids) {
      // A start of this key during an await owns the key now, and on iOS may hold one of these
      // ids: whatever is left is the new owner's to settle.
      if (_generation[key] != generation) return;
      try {
        await _tiles.delete(id);
        if (_generation[key] == generation) {
          _older[key]?.remove(id);
          if (_ids[key] == id) _ids.remove(key);
        }
      } catch (error) {
        failure ??= error;
      }
    }
    if (_generation[key] != generation) return;
    if (failure != null) {
      _set(key, const Failed(PackFailure.other));
      throw failure;
    }
    _older.remove(key);
    _requests.remove(key);
    _clear(key);
  }

  /// Reads the database and updates every pack this session is not downloading: a complete
  /// region becomes [Complete], an unfinished one [Interrupted], and a pack that is gone leaves
  /// the state. When a key has several regions (a download that began again beside the old
  /// one), the **complete** one wins whatever the ids (iOS ids are not ordered) and the others
  /// are deleted; with none complete the highest id is kept. Regions another tool made (without
  /// this package's key) are ignored.
  Future<void> refresh() async {
    final List<StoredRegion> regions;
    try {
      regions = await _tiles.regions();
    } catch (_) {
      return;
    }
    final byKey = <String, List<StoredRegion>>{};
    for (final region in regions) {
      final request = region.request;
      if (request == null) continue;
      (byKey[request.key] ??= []).add(region);
    }
    final generations = {
      for (final key in byKey.keys) key: _generation[key] ?? 0,
    };
    final chosen = <String, ({StoredRegion region, PackStatus status})>{};
    final spare = <String, List<int>>{};
    for (final entry in byKey.entries) {
      final key = entry.key;
      if (_isActive(state[key])) continue;
      final statuses = <int, RegionStatus?>{};
      for (final region in entry.value) {
        try {
          statuses[region.id] = await _tiles.status(region.id);
        } catch (_) {
          statuses[region.id] = null;
        }
      }
      StoredRegion? best;
      for (final region in entry.value) {
        final done = statuses[region.id]?.isComplete ?? false;
        final bestDone = best == null
            ? false
            : (statuses[best.id]?.isComplete ?? false);
        if (best == null ||
            (done && !bestDone) ||
            (done == bestDone && region.id > best.id)) {
          best = region;
        }
      }
      final status = statuses[best!.id];
      chosen[key] = (
        region: best,
        status: status == null
            ? const Interrupted()
            : status.isComplete
            ? Complete(bytes: status.bytes)
            : Interrupted(progress: status.progress, bytes: status.bytes),
      );
      spare[key] = [
        for (final region in entry.value)
          if (region.id != best.id) region.id,
      ];
    }
    if (!ref.mounted) return;
    // One synchronous pass over the state as it is now: a pack that started (or was removed)
    // while the statuses were read is left to that call.
    final next = {...state};
    final toDelete = <({String key, int id, int generation})>[];
    for (final entry in chosen.entries) {
      final key = entry.key;
      if (_isActive(state[key]) ||
          (_generation[key] ?? 0) != generations[key]) {
        continue;
      }
      next[key] = entry.value.status;
      _ids[key] = entry.value.region.id;
      _requests[key] = entry.value.region.request!;
      if (entry.value.status is Complete) {
        _older.remove(key);
        for (final id in spare[key]!) {
          toDelete.add((key: key, id: id, generation: _generation[key] ?? 0));
        }
      } else {
        _older[key] = {...spare[key]!};
      }
    }
    for (final key in state.keys) {
      if (byKey.containsKey(key)) continue;
      final current = state[key];
      // A pack with no region is gone, unless a download is making one or has just failed.
      if (current is Complete || current is Interrupted) {
        next.remove(key);
        _ids.remove(key);
        _older.remove(key);
        _requests.remove(key);
      }
    }
    state = next;
    for (final entry in toDelete) {
      // Skip what a start or a removal of the key took over since the regions were read (on iOS
      // it may be running on one of these ids).
      if (!ref.mounted ||
          (_generation[entry.key] ?? 0) != entry.generation ||
          _isActive(state[entry.key])) {
        continue;
      }
      await _tryDelete(entry.id);
    }
  }

  /// What the packs take: the bytes of each (from the state, which [refresh] fills for packs of
  /// earlier sessions) and the size of the database file.
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
    int? onDisk;
    try {
      onDisk = await _tiles.databaseBytes();
    } catch (_) {
      onDisk = null;
    }
    return StorageUse(perPack: perPack, onDisk: onDisk);
  }
}
