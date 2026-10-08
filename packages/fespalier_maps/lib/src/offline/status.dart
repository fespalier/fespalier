import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;

/// Why a pack download failed, as a value an app can render. No text of the platform's is kept:
/// it can carry a URL.
enum PackFailure {
  /// This platform has no offline downloads (the web), or the plugin is not there.
  unsupported,

  /// The request cannot be downloaded: an empty key, a bad zoom range, a rectangle that crosses
  /// the antimeridian, or a region the style does not allow.
  invalidRegion,

  /// MapLibre refused to go on: the region needs more tiles than its limit.
  limitExceeded,

  /// Another pack of the app has the same style, rectangle and zoom range. MapLibre treats the two
  /// as one region (starting one deletes the other's), so `TilePacks` refuses the second.
  duplicateRegion,

  /// MapLibre removed the region under the download: another download of the same area replaced
  /// it, it was deleted, or the database was reset.
  replaced,

  /// Anything else.
  other;

  /// The failure an error stands for: what the download call threw, or the error an event
  /// carried.
  static PackFailure of(Object error) {
    if (error is UnsupportedError || error is MissingPluginException) {
      return unsupported;
    }
    if (error is PlatformException) {
      return switch (error.code) {
        'tileCountLimitExceeded' => limitExceeded,
        'invalidRegionDefinition' => invalidRegion,
        'RegionReplaced' || 'RegionDeleted' || 'DatabaseReset' => replaced,
        _ => other,
      };
    }
    if (error is ArgumentError) return invalidRegion;
    return other;
  }
}

/// Where one pack is, as `TilePacks` holds it per key (since 0.13.0).
///
/// MapLibre counts **resources** (tiles, glyph ranges, sprites, the style), not tiles, so the
/// counts here are resources and `progress` is MapLibre's own fraction (0 to 1).
@immutable
sealed class PackStatus {
  const PackStatus();
}

/// No pack under this key.
final class Absent extends PackStatus {
  /// No pack.
  const Absent();

  @override
  bool operator ==(Object other) => other is Absent;

  @override
  int get hashCode => 0;
}

/// A download is running in this session.
final class Downloading extends PackStatus {
  /// A download at [progress] (0 to 1): [completedResources] of [requiredResources] (the second
  /// grows as MapLibre discovers more), [bytes] stored so far.
  const Downloading({
    this.progress = 0,
    this.completedResources = 0,
    this.requiredResources = 0,
    this.bytes = 0,
  });

  /// MapLibre's fraction, 0 to 1.
  final double progress;

  /// Resources stored.
  final int completedResources;

  /// Resources known to be needed so far.
  final int requiredResources;

  /// Bytes of the stored resources.
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is Downloading &&
      other.progress == progress &&
      other.completedResources == completedResources &&
      other.requiredResources == requiredResources &&
      other.bytes == bytes;

  @override
  int get hashCode =>
      Object.hash(progress, completedResources, requiredResources, bytes);
}

/// A download this session paused, and can resume while the app stays alive.
final class Paused extends PackStatus {
  /// Paused at [progress] with [bytes] stored.
  const Paused({this.progress = 0, this.bytes = 0});

  /// MapLibre's fraction when it was paused.
  final double progress;

  /// Bytes stored.
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is Paused && other.progress == progress && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(progress, bytes);
}

/// Every resource is stored: the region draws offline.
final class Complete extends PackStatus {
  /// A complete pack of [bytes].
  const Complete({this.bytes = 0});

  /// Bytes of the pack's resources. Resources shared with another pack are counted in each.
  final int bytes;

  @override
  bool operator ==(Object other) => other is Complete && other.bytes == bytes;

  @override
  int get hashCode => bytes.hashCode;
}

/// A region is in the database but no download of it is running: the app was restarted (or the
/// native side lost track) while it downloaded. It does **not** resume where it stopped:
/// `TilePacks.resume` starts the same definition again.
final class Interrupted extends PackStatus {
  /// An interrupted pack at [progress] with [bytes] stored.
  const Interrupted({this.progress = 0, this.bytes = 0});

  /// MapLibre's fraction when it stopped.
  final double progress;

  /// Bytes stored.
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is Interrupted &&
      other.progress == progress &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(progress, bytes);
}

/// A download ended in failure.
final class Failed extends PackStatus {
  /// Failed for [reason].
  const Failed(this.reason);

  /// Why.
  final PackFailure reason;

  @override
  bool operator ==(Object other) => other is Failed && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}
