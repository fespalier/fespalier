import 'package:flutter/foundation.dart';

import 'request.dart';
import 'status.dart';

/// One event of a running download, in the order MapLibre reported them.
@immutable
sealed class DownloadEvent {
  const DownloadEvent();
}

/// The download advanced.
final class DownloadProgress extends DownloadEvent {
  /// [progress] is 0 to 1; the counts are resources, not tiles.
  const DownloadProgress({
    required this.progress,
    this.completedResources = 0,
    this.requiredResources = 0,
    this.bytes = 0,
  });

  /// MapLibre's fraction.
  final double progress;

  /// Resources stored.
  final int completedResources;

  /// Resources known to be needed.
  final int requiredResources;

  /// Bytes stored.
  final int bytes;
}

/// Every resource is stored.
final class DownloadFinished extends DownloadEvent {
  /// The end of a successful download.
  const DownloadFinished();
}

/// The download ended without finishing.
final class DownloadFailed extends DownloadEvent {
  /// A failure for [reason].
  const DownloadFailed(this.reason);

  /// Why.
  final PackFailure reason;
}

/// A region as the database holds it.
@immutable
final class StoredRegion {
  /// A region with MapLibre's [id]. [request] is what this package stored with it, or null for a
  /// region something else made.
  const StoredRegion({required this.id, this.request});

  /// MapLibre's id, valid until the region is deleted.
  final int id;

  /// The definition, with the key this package gave it; null when the region has no key of ours.
  final RegionPackRequest? request;
}

/// How far one stored region got.
@immutable
final class RegionStatus {
  /// A status.
  const RegionStatus({
    required this.progress,
    required this.completedResources,
    required this.requiredResources,
    required this.bytes,
    required this.isComplete,
  });

  /// MapLibre's fraction, 0 to 1.
  final double progress;

  /// Resources stored.
  final int completedResources;

  /// Resources known to be needed.
  final int requiredResources;

  /// Bytes stored.
  final int bytes;

  /// Whether every resource is stored.
  final bool isComplete;
}

/// The offline database under the packs: the port that `TilePacks` drives. The MapLibre one is
/// `MapLibreOfflineTiles` in `package:fespalier_maps/maplibre.dart`, a fake is `FakeOfflineTiles`
/// in `testing.dart`.
///
/// An implementation reports a download's events through the callback it is given, in order, and
/// never after the download ended. It throws on failure; `PackFailure.of` says what a thrown
/// error stands for.
abstract interface class OfflineTiles {
  /// Every region in the database.
  Future<List<StoredRegion>> regions();

  /// Starts downloading [request] and completes with the region **as soon as it exists**, while
  /// the download goes on; [onEvent] hears it, and may hear events before this completes.
  Future<StoredRegion> download(
    RegionPackRequest request,
    void Function(DownloadEvent event) onEvent,
  );

  /// Pauses the running download of region [id].
  Future<void> pause(int id);

  /// Resumes a download of this session that [pause] paused. Throws when the native side no
  /// longer tracks it (after a restart).
  Future<void> resume(int id);

  /// Deletes region [id] and what only it needed.
  Future<void> delete(int id);

  /// How far region [id] got.
  Future<RegionStatus> status(int id);

  /// The size of the whole offline database file, or null when it cannot be known.
  Future<int?> databaseBytes();
}
