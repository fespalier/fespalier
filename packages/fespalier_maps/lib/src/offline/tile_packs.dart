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
final tilePackStatus = Provider.family<PackStatus, String>(
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
/// interrupted pack starts the same definition again (it may fetch resources it already has) and
/// removes the old region once the new one completes. Pause and resume of a running download
/// work within the session only.
class TilePacks extends Notifier<Map<String, PackStatus>> {
  late OfflineTiles _tiles;

  // Per key: the id of the region the running (or last) download made.
  final Map<String, int> _ids = {};
  // Per key: ids of older regions of the same key, deleted when a newer download completes.
  final Map<String, Set<int>> _older = {};
  // Per key: the definition, for starting it again.
  final Map<String, RegionPackRequest> _requests = {};
  // Per key: bumped by every start and removal, so an event of a download that is over is dropped.
  final Map<String, int> _generation = {};
  // Per key: the telemetry operation of the running download.
  final Map<String, Object?> _spans = {};

  @override
  Map<String, PackStatus> build() {
    _tiles = ref.watch(offlineTiles);
    _ids.clear();
    _older.clear();
    _requests.clear();
    _generation.clear();
    _spans.clear();
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

  bool _current(String key, int generation) =>
      ref.mounted && _generation[key] == generation;

  void _endSpan(String key, String result, {String? outcome}) {
    final token = _spans.remove(key);
    mapsFinish(token, result, outcome: outcome ?? TelemetryOutcome.ok);
  }

  /// Downloads [request]. Does nothing while a download of the same key is running or paused;
  /// a complete pack is downloaded again (remove it first to keep the old one out). A request
  /// that is not [RegionPackRequest.isValid] ends in [Failed] with
  /// [PackFailure.invalidRegion], and nothing reaches MapLibre.
  ///
  /// Completes when MapLibre has accepted the region, not when the download ends: the end is
  /// [Complete] or [Failed] in [state].
  Future<void> start(RegionPackRequest request) async {
    final current = state[request.key];
    if (current is Downloading || current is Paused) return;
    await _begin(request);
  }

  Future<void> _begin(RegionPackRequest request) async {
    final key = request.key;
    if (!request.isValid) {
      if (key.isNotEmpty) _set(key, const Failed(PackFailure.invalidRegion));
      return;
    }
    final generation = (_generation[key] ?? 0) + 1;
    _generation[key] = generation;
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
      // Removed (or started again) while MapLibre made the region: nobody owns it.
      await _tryDelete(region.id);
      return;
    }
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
        if (status is! Downloading && status is! Paused) return;
        final bytes = switch (status) {
          Downloading(:final bytes) => bytes,
          Paused(:final bytes) => bytes,
          _ => 0,
        };
        _set(key, Complete(bytes: bytes));
        _endSpan(key, MapsTelemetry.resultComplete);
        if (_ids.containsKey(key)) unawaited(_settle(key, generation));
      case DownloadFailed():
        if (status is! Downloading && status is! Paused) return;
        _endSpan(
          key,
          MapsTelemetry.resultFailed,
          outcome: TelemetryOutcome.error,
        );
        _set(key, Failed(event.reason));
    }
  }

  /// After a pack completed: read its final size, and delete the older regions of the same key.
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
      await _tryDelete(old);
    }
  }

  Future<void> _tryDelete(int id) async {
    try {
      await _tiles.delete(id);
    } catch (_) {
      // A region that is already gone (MapLibre removes one that hit its tile limit).
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
  /// - [Interrupted] or [Failed]: the definition is downloaded **again** as a new region; the old
  ///   one is deleted when the new one completes. Resources MapLibre already stored may be
  ///   reused or fetched again (not verified on a device). This is the restart, not a resume
  ///   from a byte offset.
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
  /// [PackFailure.other] and the error is rethrown.
  Future<void> remove(String key) async {
    final generation = (_generation[key] ?? 0) + 1;
    _generation[key] = generation;
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
      try {
        await _tiles.delete(id);
        _older[key]?.remove(id);
        if (_ids[key] == id) _ids.remove(key);
      } catch (error) {
        failure ??= error;
      }
    }
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
  /// the state. Regions another tool made (without this package's key) are ignored.
  Future<void> refresh() async {
    final List<StoredRegion> regions;
    try {
      regions = await _tiles.regions();
    } catch (_) {
      return;
    }
    final newest = <String, StoredRegion>{};
    final all = <String, Set<int>>{};
    for (final region in regions) {
      final request = region.request;
      if (request == null) continue;
      (all[request.key] ??= {}).add(region.id);
      final seen = newest[request.key];
      if (seen == null || region.id > seen.id) newest[request.key] = region;
    }
    final found = <String, PackStatus>{};
    for (final entry in newest.entries) {
      final active = state[entry.key];
      if (active is Downloading || active is Paused) continue;
      try {
        final s = await _tiles.status(entry.value.id);
        found[entry.key] = s.isComplete
            ? Complete(bytes: s.bytes)
            : Interrupted(progress: s.progress, bytes: s.bytes);
      } catch (_) {
        found[entry.key] = const Interrupted();
      }
    }
    if (!ref.mounted) return;
    // One synchronous pass over the state as it is now: a pack that started while the statuses
    // were read keeps its download.
    final next = {...state};
    for (final entry in found.entries) {
      final current = state[entry.key];
      if (current is Downloading || current is Paused) continue;
      next[entry.key] = entry.value;
      final region = newest[entry.key]!;
      _ids[entry.key] = region.id;
      _older[entry.key] = {...all[entry.key]!}..remove(region.id);
      _requests[entry.key] = region.request!;
    }
    for (final key in state.keys) {
      if (newest.containsKey(key)) continue;
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
