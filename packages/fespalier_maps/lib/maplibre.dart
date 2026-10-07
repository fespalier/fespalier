/// The MapLibre surface of the pin picker (since 0.12.0): the one library of this package that
/// imports `maplibre_gl`, so an app that only uses the pure model never links a map.
///
/// Nothing here runs in a widget test (a platform view cannot render there): tests use
/// `FakeMapSurface` from `package:fespalier_maps/testing.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'fespalier_maps.dart';

/// A [MapSurface] over `MapLibreMap`.
///
/// Keep one instance for the life of the page: it holds the map's controller, which is how
/// [moveTo] reaches the map. It listens to nothing: the camera events are the widget's own
/// callbacks. The map is a platform view and needs a device to be seen.
class MapLibreSurface extends MapSurface {
  /// A surface drawing [styleString] (a style URL or the style's JSON). The default is
  /// MapLibre's demo style, which is for trying things out: an app uses its own tiles and
  /// follows their terms of use and attribution.
  MapLibreSurface({
    this.styleString = MapLibreStyles.demo,
    this.rotateGesturesEnabled = false,
    this.tiltGesturesEnabled = false,
    this.compassEnabled = false,
    this.minZoom,
    this.maxZoom,
  });

  /// The style URL or JSON.
  final String styleString;

  /// Whether the person may rotate the map under the pin (off by default: north is up).
  final bool rotateGesturesEnabled;

  /// Whether the person may tilt the map (off by default).
  final bool tiltGesturesEnabled;

  /// Whether the compass button shows.
  final bool compassEnabled;

  /// The lowest zoom the person may reach, or null for the style's own.
  final double? minZoom;

  /// The highest zoom the person may reach, or null for the style's own.
  final double? maxZoom;

  MapLibreMapController? _controller;
  GeoPoint? _pending;
  double? _pendingZoom;

  @override
  Widget build(
    BuildContext context,
    MapCamera initial, {
    required void Function(GeoPoint center) onIdle,
    required VoidCallback onMove,
  }) {
    return MapLibreMap(
      styleString: styleString,
      initialCameraPosition: CameraPosition(
        target: LatLng(initial.center.latitude, initial.center.longitude),
        zoom: initial.zoom,
      ),
      trackCameraPosition: true,
      rotateGesturesEnabled: rotateGesturesEnabled,
      tiltGesturesEnabled: tiltGesturesEnabled,
      compassEnabled: compassEnabled,
      minMaxZoomPreference: MinMaxZoomPreference(minZoom, maxZoom),
      onMapCreated: (controller) {
        _controller = controller;
        final pending = _pending;
        if (pending != null) {
          _pending = null;
          _apply(controller, pending, _pendingZoom, animate: false);
        }
      },
      onCameraMove: (_) => onMove(),
      onCameraIdle: () {
        final target = _controller?.cameraPosition?.target;
        if (target != null) {
          onIdle(GeoPoint(target.latitude, target.longitude));
        }
      },
    );
  }

  @override
  Future<void> moveTo(GeoPoint center, {double? zoom}) async {
    final controller = _controller;
    if (controller == null) {
      _pending = center;
      _pendingZoom = zoom;
      return;
    }
    await _apply(controller, center, zoom, animate: true);
  }

  Future<void> _apply(
    MapLibreMapController controller,
    GeoPoint center,
    double? zoom, {
    required bool animate,
  }) async {
    final target = LatLng(center.latitude, center.longitude);
    final update = zoom == null
        ? CameraUpdate.newLatLng(target)
        : CameraUpdate.newLatLngZoom(target, zoom);
    try {
      if (animate) {
        await controller.animateCamera(update);
      } else {
        await controller.moveCamera(update);
      }
    } catch (_) {
      // A controller that was disposed with its page costs the move, never the picker.
    }
  }
}
