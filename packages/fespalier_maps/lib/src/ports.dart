import 'dart:async';

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

/// The link between one picker and the map built for it: the map's events come in through it, and
/// the picker's moves go out through it, so a move can only ever reach the map it was made for.
///
/// A picker (`PinPickerModel`) owns one binding for its life and hands it to [MapSurface.build].
/// A surface implementation, once its map exists, calls [attach] with a function that moves that
/// map, forwards the map's events to [move] and [idle], and calls [detach] when the map goes.
/// Before [attach] a move is parked (the latest one) and is applied, without animation, when the
/// map arrives; after [detach] it is parked again, and [dispose] (the picker's end) drops it.
final class MapBinding {
  /// A binding that reports the map's events to [onIdle] and [onMove].
  MapBinding({
    required void Function(GeoPoint center) onIdle,
    required VoidCallback onMove,
  }) : _onIdle = onIdle,
       _onMove = onMove;

  void Function(GeoPoint center)? _onIdle;
  VoidCallback? _onMove;
  Future<void> Function(GeoPoint center, double? zoom, {required bool animate})?
  _mover;
  ({GeoPoint center, double? zoom})? _pending;
  bool _disposed = false;

  /// Whether a map is attached.
  bool get isAttached => _mover != null;

  /// Moves the camera of the attached map so that [center] is under the pin, at [zoom] when
  /// given. With no map yet the move is parked until [attach]; after [dispose] it does nothing.
  Future<void> moveTo(GeoPoint center, {double? zoom}) async {
    if (_disposed) return;
    final mover = _mover;
    if (mover == null) {
      _pending = (center: center, zoom: zoom);
      return;
    }
    await mover(center, zoom, animate: true);
  }

  /// For a surface: the map exists and [mover] moves it. A move parked before is applied now,
  /// without animation.
  void attach(
    Future<void> Function(
      GeoPoint center,
      double? zoom, {
      required bool animate,
    })
    mover,
  ) {
    if (_disposed) return;
    _mover = mover;
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      unawaited(mover(pending.center, pending.zoom, animate: false));
    }
  }

  /// For a surface: the map is gone. Its parked move, if any, goes with it.
  void detach() {
    _mover = null;
    _pending = null;
  }

  /// For a surface: the camera came to rest with [center] under the pin.
  void idle(GeoPoint center) {
    if (_disposed) return;
    _onIdle?.call(center);
  }

  /// For a surface: the camera started to move.
  void move() {
    if (_disposed) return;
    _onMove?.call();
  }

  /// The picker is done: nothing is reported to it, nothing is moved for it.
  void dispose() {
    _disposed = true;
    _mover = null;
    _pending = null;
    _onIdle = null;
    _onMove = null;
  }
}

/// The map under the pin. The MapLibre one is `MapLibreSurface` in
/// `package:fespalier_maps/maplibre.dart`; `FakeMapSurface` is in `testing.dart`.
///
/// A surface is configuration (a style, gestures) and holds no state about a picker: it can be
/// shared by several, stacked or in turn, and each map it builds belongs to the [MapBinding] it
/// was built for.
abstract class MapSurface {
  /// A surface.
  const MapSurface();

  /// The map widget for [binding], showing [initial]. Key it by [binding] so that a picker with
  /// another binding gets a new map. The map attaches itself to [binding] when it exists
  /// ([MapBinding.attach]), forwards its camera events to [MapBinding.move] (the camera starts to
  /// move: a drag, a pinch, an animation) and [MapBinding.idle] (it stopped, with the centre),
  /// and detaches when it is disposed.
  Widget build(BuildContext context, MapCamera initial, MapBinding binding);
}
