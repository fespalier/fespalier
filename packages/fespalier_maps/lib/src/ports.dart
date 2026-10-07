import 'package:flutter/widgets.dart';

import 'geo.dart';

/// Turns a query into places and a point into a name. The network and the terms of use are the
/// app's: this package has no geocoder of its own, only the recipes in the skill's
/// `geocoders.md` (Nominatim, Photon, an app backend).
///
/// Throw on failure: the picker reports it as "no answer" and never shows the error's text.
abstract interface class Geocoder {
  /// Places matching [query], best first. [near] biases the answer towards a point (the map's
  /// centre); [locale] is a BCP 47 tag for the labels.
  Future<List<PlaceGuess>> search(
    String query, {
    GeoPoint? near,
    String? locale,
  });

  /// The nearest named place to [point], or null when there is none.
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale});
}

/// What the device's position source answered: a value, never an exception, so an app renders
/// each case.
sealed class PositionFix {
  const PositionFix();
}

/// A position was found.
final class Fixed extends PositionFix {
  /// A fix at [point], accurate to about [accuracyMeters].
  const Fixed(this.point, {this.accuracyMeters});

  /// Where the device is.
  final GeoPoint point;

  /// The radius of the 68% confidence circle, when the platform says.
  final double? accuracyMeters;
}

/// The device's location service is switched off.
final class ServiceOff extends PositionFix {
  /// The location service is off.
  const ServiceOff();
}

/// The person refused the location permission.
final class Denied extends PositionFix {
  /// A refusal; [permanent] means the platform will not ask again (the person has to use the
  /// system settings).
  const Denied({this.permanent = false});

  /// Whether the platform's own prompt can no longer be shown.
  final bool permanent;
}

/// No position could be had (a timeout, a platform error, or no plugin on this platform).
final class Unavailable extends PositionFix {
  /// No position.
  const Unavailable();
}

/// Where the device is. One implementation over `geolocator` is in
/// `package:fespalier_maps/geolocator.dart`; a fake is in `testing.dart`.
abstract interface class PositionSource {
  /// One fix. May show the platform's own permission prompt (never a Flutter dialog), and
  /// completes with a [PositionFix] whatever happens.
  Future<PositionFix> current();
}

/// The map under the pin. The MapLibre one is `MapLibreSurface` in
/// `package:fespalier_maps/maplibre.dart`; `FakeMapSurface` is in `testing.dart`.
///
/// A surface may serve several pickers (stacked, or one after the other): [build] binds the callbacks
/// it is given to the map it builds, and [moveTo] moves the map that was mounted last.
abstract class MapSurface {
  /// A surface.
  const MapSurface();

  /// The map widget, showing [initial]. It calls [onMove] when the camera starts to move
  /// (a drag, a pinch, an animation) and [onIdle] with the centre when it has stopped.
  Widget build(
    BuildContext context,
    MapCamera initial, {
    required void Function(GeoPoint center) onIdle,
    required VoidCallback onMove,
  });

  /// Moves the camera so that [center] is under the pin, at [zoom] when given. Before the map
  /// exists the move is kept and applied when it does.
  Future<void> moveTo(GeoPoint center, {double? zoom});
}
