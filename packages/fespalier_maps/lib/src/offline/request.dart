import 'package:flutter/foundation.dart';

import '../geo.dart';
import '../tiles.dart';

/// The highest zoom level a region pack may reach: MapLibre's own tile grids stop near here.
const int maxPackZoom = 22;

/// What to download for one offline region pack: a rectangle, a style and a zoom range, under a
/// [key] of the app's choosing (since 0.13.0).
///
/// The [key] names the pack in `TilePacks`: `shop-douala`, `route-12`. It is stored with the
/// region in MapLibre's database so a pack can be found again after a restart, and it is
/// **never** sent to telemetry, since it often names a place.
///
/// ```dart
/// final request = RegionPackRequest(
///   key: 'douala',
///   bounds: const GeoBounds(GeoPoint(4.0, 9.65), GeoPoint(4.12, 9.8)),
///   styleUrl: 'https://tiles.example.com/style.json',
///   minZoom: 10,
///   maxZoom: 14,
/// );
/// request.isValid; // true
/// request.estimatedTiles; // the Web Mercator tiles the rectangle covers on those levels
/// ```
@immutable
final class RegionPackRequest {
  /// A request for [bounds] drawn with [styleUrl] from [minZoom] to [maxZoom].
  const RegionPackRequest({
    required this.key,
    required this.bounds,
    required this.styleUrl,
    required this.minZoom,
    required this.maxZoom,
  });

  /// The app's name for the pack. Must not be empty.
  final String key;

  /// The rectangle. One that crosses the antimeridian is refused ([isValid] is false): split it
  /// into two packs.
  final GeoBounds bounds;

  /// The style URL the tiles, glyphs and sprites are fetched through. The pack holds what that
  /// style needs; a different style needs its own pack.
  final String styleUrl;

  /// The lowest zoom level, from 0.
  final double minZoom;

  /// The highest zoom level, to [maxPackZoom].
  final double maxZoom;

  /// Whether this can be downloaded: a key, a style, finite zoom levels in order and in range,
  /// and a rectangle whose south is not north of its north and that does not cross the
  /// antimeridian.
  bool get isValid =>
      key.isNotEmpty &&
      styleUrl.isNotEmpty &&
      minZoom.isFinite &&
      maxZoom.isFinite &&
      minZoom >= 0 &&
      maxZoom >= minZoom &&
      maxZoom <= maxPackZoom &&
      bounds.southwest.latitude <= bounds.northeast.latitude &&
      !bounds.crossesAntimeridian;

  /// How many tiles of the standard pyramid cover [bounds] on the whole levels from [minZoom]
  /// to [maxZoom] (see `tileCount`), for showing the size of a choice before anything is
  /// fetched. It counts tiles only: a pack also holds glyphs, sprites and the style, and the
  /// vector tiles of a level are not all the same size, so it is not a size in bytes. Throws an
  /// [ArgumentError] when the zoom range is not valid.
  int get estimatedTiles =>
      tileCount(bounds, minZoom: minZoom.floor(), maxZoom: maxZoom.floor());

  @override
  bool operator ==(Object other) =>
      other is RegionPackRequest &&
      other.key == key &&
      other.bounds == bounds &&
      other.styleUrl == styleUrl &&
      other.minZoom == minZoom &&
      other.maxZoom == maxZoom;

  @override
  int get hashCode => Object.hash(key, bounds, styleUrl, minZoom, maxZoom);

  // No fields in the text: the key and the bounds name a place.
  @override
  String toString() => 'RegionPackRequest';
}
