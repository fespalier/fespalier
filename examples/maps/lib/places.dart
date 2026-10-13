import 'dart:math' as math;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/geolocator.dart';
import 'package:fespalier_maps/maplibre.dart';

/// The style URL of the map. This default is MapLibre's demo style: it is for trying things out
/// (a world map with country borders and no street detail), not for production. Run with
/// `--dart-define=MAP_STYLE_URL=https://your.tiles/style.json` to use your own, and follow its
/// attribution. Tests never read it: they override [mapSurface].
const mapStyleUrl = String.fromEnvironment(
  'MAP_STYLE_URL',
  defaultValue: 'https://demotiles.maplibre.org/style.json',
);

/// The map under the pin. A `MapLibreSurface` is configuration, so a `const` is fine; it is a
/// platform view and cannot draw in a widget test, which overrides this with a `FakeMapSurface`.
final mapSurface = Provider<MapSurface>(
  (ref) => const MapLibreSurface(styleString: mapStyleUrl),
);

/// Where the device is. The tests override it with a `FakePositionSource`.
final positionSource = Provider<PositionSource>(
  (ref) => const GeolocatorPositionSource(),
);

/// Names and finds places. A fixed list in the app, so there is no network call and no usage
/// policy to follow; see the skill's `geocoders.md` for Nominatim, Photon and your own backend.
final geocoder = Provider<Geocoder>((ref) => const Gazetteer(cameroon));

/// A few cities of Cameroon, enough to show a name for a point and a search.
const cameroon = [
  PlaceGuess(GeoPoint(4.0511, 9.7679), 'Douala', detail: 'Littoral'),
  PlaceGuess(GeoPoint(3.8480, 11.5021), 'Yaoundé', detail: 'Centre'),
  PlaceGuess(GeoPoint(5.4737, 10.4179), 'Bafoussam', detail: 'West'),
  PlaceGuess(GeoPoint(5.9631, 10.1591), 'Bamenda', detail: 'North-West'),
  PlaceGuess(GeoPoint(4.1527, 9.2431), 'Buea', detail: 'South-West'),
  PlaceGuess(GeoPoint(9.3000, 13.3921), 'Garoua', detail: 'North'),
];

/// A [Geocoder] over a fixed list, with no network. Reverse answers the nearest entry within
/// [maxMeters] and nothing farther: a name for a point far from every city would be a worse guess
/// than none. Search matches the start of a name, nearest to `near` first.
class Gazetteer implements Geocoder {
  /// A gazetteer of [places].
  const Gazetteer(this.places, {this.maxMeters = 60000});

  /// The places it knows.
  final List<PlaceGuess> places;

  /// How far a reverse answer may be from the point asked about.
  final double maxMeters;

  @override
  Future<List<PlaceGuess>> search(
    String query, {
    GeoPoint? near,
    String? locale,
  }) async {
    final wanted = query.trim().toLowerCase();
    if (wanted.isEmpty) return const [];
    final found = places
        .where((p) => p.label.toLowerCase().startsWith(wanted))
        .toList();
    if (near != null) {
      found.sort(
        (a, b) => metersBetween(
          near,
          a.point,
        ).compareTo(metersBetween(near, b.point)),
      );
    }
    return found;
  }

  @override
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale}) async {
    PlaceGuess? best;
    var bestMeters = maxMeters;
    for (final place in places) {
      final meters = metersBetween(point, place.point);
      if (meters <= bestMeters) {
        best = place;
        bestMeters = meters;
      }
    }
    // The guess is about the point under the pin, not about the city's own coordinate.
    return best == null
        ? null
        : PlaceGuess(point, best.label, detail: best.detail);
  }
}

/// The great-circle distance between two points, in metres (haversine).
double metersBetween(GeoPoint a, GeoPoint b) {
  const earth = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLon = rad(b.longitude - a.longitude);
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.latitude)) *
          math.cos(rad(b.latitude)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * earth * math.asin(math.sqrt(h));
}
