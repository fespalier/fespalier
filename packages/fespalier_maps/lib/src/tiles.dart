import 'dart:math' as math;

import 'geo.dart';

/// The latitude at which Web Mercator ends: the tile grid has no row beyond it.
const double _maxMercatorLatitude = 85.0511287798066;

/// How many tiles of the standard Web Mercator pyramid (256 px, `z/x/y`, 2^z by 2^z) cover
/// [bounds] on the zoom levels [minZoom] to [maxZoom], both included.
///
/// Pure arithmetic with no map in it, for sizing a region before anything is downloaded (the
/// offline packs of a later release use it). The tiles counted are those from the one that holds
/// the north-west corner to the one that holds the south-east corner; a coordinate exactly on a
/// tile border belongs to the tile east of it or south of it. Latitudes beyond ±85.0511° are
/// clamped, and a rectangle that crosses the antimeridian is counted in both halves.
///
/// ```dart
/// tileCount(
///   const GeoBounds(GeoPoint(-80, -179), GeoPoint(80, 179)),
///   minZoom: 0,
///   maxZoom: 1,
/// ); // 5: the one tile of zoom 0, the four of zoom 1
/// ```
int tileCount(GeoBounds bounds, {required int minZoom, required int maxZoom}) {
  if (minZoom < 0 || maxZoom < minZoom) {
    throw ArgumentError.value(
      '$minZoom..$maxZoom',
      'zoom',
      'needs 0 <= minZoom <= maxZoom',
    );
  }
  if (maxZoom > 30) {
    throw ArgumentError.value(maxZoom, 'maxZoom', 'is above 30');
  }
  final south = _row(bounds.southwest.latitude);
  final north = _row(bounds.northeast.latitude);
  final west = bounds.southwest.longitude;
  final east = bounds.northeast.longitude;
  var total = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final n = 1 << z;
    // Row 0 is the north edge, so the northern latitude has the smaller row.
    final rows = _span(north(z), south(z));
    final int columns;
    if (bounds.crossesAntimeridian) {
      columns = _span(_column(west, n), n - 1) + _span(0, _column(east, n));
    } else {
      columns = _span(_column(west, n), _column(east, n));
    }
    total += rows * columns;
  }
  return total;
}

/// The rows of a latitude on each zoom level.
int Function(int z) _row(double latitude) {
  final clamped = latitude.clamp(-_maxMercatorLatitude, _maxMercatorLatitude);
  final radians = clamped * math.pi / 180;
  final y =
      (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) / 2;
  return (z) => _clampIndex((y * (1 << z)).floor(), 1 << z);
}

int _column(double longitude, int n) =>
    _clampIndex(((longitude + 180) / 360 * n).floor(), n);

int _clampIndex(int index, int n) => index < 0
    ? 0
    : index > n - 1
    ? n - 1
    : index;

int _span(int first, int last) => last < first ? 0 : last - first + 1;
