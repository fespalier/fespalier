import 'dart:async';

import 'port.dart';
import 'request.dart';
import 'status.dart';

/// What [FakeOfflineTiles.download] does with a region that already has the new one's style,
/// rectangle and zoom range, whatever its key: `maplibre_gl` 0.27 treats the two as one region.
enum FakeDuplicates {
  /// Android: the old region is deleted before the new one is created (it gets a new id), and an
  /// old download still running hears `RegionReplaced` (a [DownloadFailed] with
  /// [PackFailure.replaced]).
  deleteAtDownload,

  /// iOS: the new region takes the old one's id, and the old download hears the same error.
  reuseId,

  /// Not the plugin's behaviour: both regions stay. For a test that wants two.
  keep,
}

/// One region a [FakeOfflineTiles] holds.
final class FakeRegion {
  FakeRegion._(this.id, this.request);

  /// The id the fake gave it.
  final int id;

  /// What was asked for.
  final RegionPackRequest request;

  /// The last fraction reported.
  double progress = 0;

  /// The last resource counts reported.
  int completedResources = 0;

  /// The last required count reported.
  int requiredResources = 0;

  /// The last byte count reported.
  int bytes = 0;

  /// Whether the download finished.
  bool isComplete = false;

  /// Whether the download is paused.
  bool paused = false;

  void Function(DownloadEvent event)? _onEvent;
  bool _tracked = true;
}

/// An [OfflineTiles] that is a list in memory, played by the test: no platform channel, no
/// network. A test starts a download through `TilePacks`, then plays MapLibre with [progress],
/// [finish] and [fail] (by the pack's key), and checks [paused], [deleted] and the regions.
///
/// Like the plugin it models, it deletes a region with the same definition when another is
/// downloaded ([duplicates]), tells a download whose region is deleted or replaced
/// ([PackFailure.replaced]), and throws when it is asked to delete or resume what is not there.
/// Progress at this port is a fraction from 0 to 1; the 0 to 100 of the native side is converted
/// in `maplibre.dart`, which has its own test.
///
/// [restart] plays the app being closed and opened again: the regions stay, nothing tracks their
/// downloads, so [resume] of an old one throws the way MapLibre's does.
class FakeOfflineTiles implements OfflineTiles {
  /// An empty database. With [holdDownloads] the future of [download] waits for
  /// [releaseDownloads], while events can already be played (the order MapLibre has).
  FakeOfflineTiles({
    this.holdDownloads = false,
    this.databaseSize,
    this.duplicates = FakeDuplicates.deleteAtDownload,
  });

  /// Whether [download] waits for [releaseDownloads].
  final bool holdDownloads;

  /// What a download of an existing definition does.
  final FakeDuplicates duplicates;

  /// What [databaseBytes] answers.
  int? databaseSize;

  /// When set, [download] throws it.
  Object? downloadError;

  /// When set, [pause] throws it.
  Object? pauseError;

  /// When set, [resume] throws it (a restart sets one by itself on old regions).
  Object? resumeError;

  /// When set, [delete] throws it.
  Object? deleteError;

  /// When set, [regions] throws it.
  Object? regionsError;

  final List<FakeRegion> _regions = [];
  final List<Completer<void>> _held = [];
  int _nextId = 1;

  /// The regions now, oldest first.
  List<FakeRegion> get all => List.unmodifiable(_regions);

  /// Every request [download] received, in order.
  final List<RegionPackRequest> downloads = [];

  /// Ids passed to [pause], in order.
  final List<int> pauses = [];

  /// Ids passed to [resume], in order.
  final List<int> resumes = [];

  /// Ids passed to [delete], in order (counted even if [deleteError] made it throw).
  final List<int> deleted = [];

  /// The region of the newest download of [key], or null.
  FakeRegion? regionOf(String key) {
    for (final region in _regions.reversed) {
      if (region.request.key == key) return region;
    }
    return null;
  }

  /// Puts a region into the database as an earlier session left it: complete, or at [progress]
  /// with nothing tracking it.
  FakeRegion seed(
    RegionPackRequest request, {
    bool complete = true,
    double progress = 0.5,
    int bytes = 1000,
  }) {
    final region = FakeRegion._(_nextId++, request)
      ..isComplete = complete
      ..progress = complete ? 1 : progress
      ..bytes = bytes
      .._tracked = false;
    _regions.add(region);
    return region;
  }

  /// Plays the app being closed and opened again: no download is tracked any more.
  void restart() {
    for (final region in _regions) {
      region._tracked = false;
      region._onEvent = null;
    }
  }

  /// MapLibre reports progress on the newest download of [key].
  void progress(
    String key,
    double fraction, {
    int completedResources = 0,
    int requiredResources = 0,
    int bytes = 0,
  }) {
    final region = regionOf(key);
    if (region == null || region._onEvent == null) return;
    region
      ..progress = fraction
      ..completedResources = completedResources
      ..requiredResources = requiredResources
      ..bytes = bytes;
    region._onEvent!(
      DownloadProgress(
        progress: fraction,
        completedResources: completedResources,
        requiredResources: requiredResources,
        bytes: bytes,
      ),
    );
  }

  /// MapLibre reports the end of the newest download of [key].
  void finish(String key, {int? bytes}) {
    final region = regionOf(key);
    if (region == null || region._onEvent == null) return;
    region
      ..isComplete = true
      ..progress = 1
      ..bytes = bytes ?? region.bytes;
    final listener = region._onEvent!;
    region._onEvent = null;
    listener(const DownloadFinished());
  }

  /// MapLibre reports that the newest download of [key] failed.
  void fail(String key, PackFailure reason) {
    final region = regionOf(key);
    if (region == null || region._onEvent == null) return;
    final listener = region._onEvent!;
    region._onEvent = null;
    listener(DownloadFailed(reason));
  }

  final List<Completer<void>> _heldDeletes = [];

  /// Whether [delete] waits for [releaseDeletes] before it takes effect, to put another call
  /// between a delete and the next one.
  bool holdDeletes = false;

  /// Lets the held [delete] calls take effect.
  void releaseDeletes() {
    final held = List.of(_heldDeletes);
    _heldDeletes.clear();
    for (final completer in held) {
      completer.complete();
    }
  }

  /// Lets the held [download] futures complete.
  void releaseDownloads() {
    final held = List.of(_held);
    _held.clear();
    for (final completer in held) {
      completer.complete();
    }
  }

  @override
  Future<List<StoredRegion>> regions() async {
    final error = regionsError;
    if (error != null) throw error;
    return [
      for (final region in _regions)
        StoredRegion(id: region.id, request: region.request),
    ];
  }

  @override
  Future<StoredRegion> download(
    RegionPackRequest request,
    void Function(DownloadEvent event) onEvent,
  ) async {
    downloads.add(request);
    var id = _nextId++;
    for (final old in List.of(_regions)) {
      if (duplicates == FakeDuplicates.keep ||
          !_sameDefinition(old.request, request)) {
        continue;
      }
      _tell(old, const DownloadFailed(PackFailure.replaced));
      _regions.remove(old);
      if (duplicates == FakeDuplicates.reuseId) id = old.id;
    }
    // Android deletes the duplicate first, so a download that then fails has lost the old pack.
    final error = downloadError;
    if (error != null) throw error;
    final region = FakeRegion._(id, request).._onEvent = onEvent;
    _regions.add(region);
    if (holdDownloads) {
      final completer = Completer<void>();
      _held.add(completer);
      await completer.future;
    }
    return StoredRegion(id: region.id, request: request);
  }

  static bool _sameDefinition(RegionPackRequest a, RegionPackRequest b) =>
      a.bounds == b.bounds &&
      a.styleUrl == b.styleUrl &&
      a.minZoom == b.minZoom &&
      a.maxZoom == b.maxZoom;

  void _tell(FakeRegion region, DownloadEvent event) {
    final listener = region._onEvent;
    region._onEvent = null;
    listener?.call(event);
  }

  FakeRegion? _byId(int id) {
    for (final region in _regions) {
      if (region.id == id) return region;
    }
    return null;
  }

  @override
  Future<void> pause(int id) async {
    pauses.add(id);
    final error = pauseError;
    if (error != null) throw error;
    _byId(id)?.paused = true;
  }

  @override
  Future<void> resume(int id) async {
    resumes.add(id);
    final error = resumeError;
    if (error != null) throw error;
    final region = _byId(id);
    if (region == null || !region._tracked) {
      throw StateError('Region is no longer actively tracked.');
    }
    region.paused = false;
  }

  @override
  Future<void> delete(int id) async {
    deleted.add(id);
    final error = deleteError;
    if (error != null) throw error;
    if (holdDeletes) {
      final completer = Completer<void>();
      _heldDeletes.add(completer);
      await completer.future;
    }
    final region = _byId(id);
    if (region == null) throw StateError('No such region.');
    _tell(region, const DownloadFailed(PackFailure.replaced));
    _regions.remove(region);
  }

  @override
  Future<RegionStatus> status(int id) async {
    final region = _byId(id);
    if (region == null) throw StateError('No such region.');
    return RegionStatus(
      progress: region.progress,
      completedResources: region.completedResources,
      requiredResources: region.requiredResources,
      bytes: region.bytes,
      isComplete: region.isComplete,
    );
  }

  @override
  Future<int?> databaseBytes() async => databaseSize;
}
