import 'package:flutter/foundation.dart';

/// A point on Earth, in degrees (WGS 84).
///
/// The coordinate is the truth about a place: a label is only ever a guess about it
/// ([PlaceGuess]). `toString` prints the coordinate, so never put one in a log or in telemetry.
@immutable
final class GeoPoint {
  /// A point at [latitude] (-90 to 90) and [longitude] (-180 to 180).
  const GeoPoint(this.latitude, this.longitude)
    : assert(latitude >= -90 && latitude <= 90, 'latitude is out of range'),
      assert(
        longitude >= -180 && longitude <= 180,
        'longitude is out of range',
      );

  /// Degrees north of the equator.
  final double latitude;

  /// Degrees east of the prime meridian.
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint($latitude, $longitude)';
}

/// A rectangle on Earth. When [southwest] is east of [northeast] (its longitude is larger) the
/// rectangle crosses the antimeridian.
@immutable
final class GeoBounds {
  /// The rectangle between [southwest] and [northeast].
  const GeoBounds(this.southwest, this.northeast);

  /// The south-west corner.
  final GeoPoint southwest;

  /// The north-east corner.
  final GeoPoint northeast;

  /// Whether the rectangle crosses the antimeridian.
  bool get crossesAntimeridian => southwest.longitude > northeast.longitude;

  @override
  bool operator ==(Object other) =>
      other is GeoBounds &&
      other.southwest == southwest &&
      other.northeast == northeast;

  @override
  int get hashCode => Object.hash(southwest, northeast);

  @override
  String toString() => 'GeoBounds($southwest, $northeast)';
}

/// What a map shows: its centre and its zoom level.
@immutable
final class MapCamera {
  /// A camera on [center] at [zoom] (a street level view by default).
  const MapCamera(this.center, {this.zoom = 15});

  /// The whole world, for a picker that has neither an initial place nor a position.
  static const MapCamera world = MapCamera(GeoPoint(0, 0), zoom: 1);

  /// The point under the pin.
  final GeoPoint center;

  /// The zoom level (0 is the whole world, 15 is a street).
  final double zoom;

  @override
  bool operator ==(Object other) =>
      other is MapCamera && other.center == center && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(center, zoom);

  @override
  String toString() => 'MapCamera($center, zoom: $zoom)';
}

/// A name for a point, and nothing more than a guess.
///
/// A geocoder answers with the nearest address or place it knows. The person may be standing
/// elsewhere, the data may be old, and a typed query may match a different town: show a label
/// as "best guess", never as fact.
@immutable
final class PlaceGuess {
  /// A guess that [label] names [point]; [detail] is a longer line (a street, a region).
  const PlaceGuess(this.point, this.label, {this.detail});

  /// Where the guess says the place is.
  final GeoPoint point;

  /// The short name.
  final String label;

  /// A second line, when the geocoder has one.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is PlaceGuess &&
      other.point == point &&
      other.label == label &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(point, label, detail);

  @override
  String toString() => 'PlaceGuess($point, $label)';
}

/// What a picker returns: the point under the pin, which is the truth, and the guess that named
/// it when there was one.
@immutable
final class PickedPlace {
  /// A place at [point], named by [guess] when a geocoder answered for exactly that point.
  const PickedPlace(this.point, {this.guess});

  /// The point under the pin when the person confirmed.
  final GeoPoint point;

  /// The geocoder's guess for [point], or null: it did not answer, was still asking, or knows
  /// nothing there. Store [point]; keep the guess as a courtesy label.
  final PlaceGuess? guess;

  @override
  bool operator ==(Object other) =>
      other is PickedPlace && other.point == point && other.guess == guess;

  @override
  int get hashCode => Object.hash(point, guess);

  @override
  String toString() => 'PickedPlace($point, guess: $guess)';
}
