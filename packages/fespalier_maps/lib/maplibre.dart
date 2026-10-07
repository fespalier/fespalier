/// The MapLibre surface of the pin picker (since 0.12.0): the one library of this package that
/// imports `maplibre_gl`, so an app that only uses the pure model never links a map.
///
/// Nothing here runs in a widget test (a platform view cannot render there): tests use
/// `FakeMapSurface` from `package:fespalier_maps/testing.dart`.
library;

import 'package:flutter/widgets.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'fespalier_maps.dart';

/// A [MapSurface] over `MapLibreMap`: configuration only, with value equality.
///
/// It holds no state about a picker, so one surface can be shared by any number of them, stacked
/// (a pickup picker that pushes a drop-off picker) or in turn: each map it builds belongs to the
/// [MapBinding] it was built for, keeps its own controller, and receives only the moves that
/// binding makes. `MapLibreMap` captures its camera callbacks once, when the platform view is
/// created; the ones given to it here call the binding, which is the same for the map's life. It
/// listens to nothing. The map is a platform view and needs a device to be seen.
class MapLibreSurface extends MapSurface {
  /// A surface drawing [styleString] (a style URL or the style's JSON). The default is
  /// MapLibre's demo style, which is for trying things out: an app uses its own tiles and
  /// follows their terms of use and attribution.
  const MapLibreSurface({
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

  @override
  Widget build(BuildContext context, MapCamera initial, MapBinding binding) =>
      _MapLibreHost(
        key: ValueKey<MapBinding>(binding),
        surface: this,
        initial: initial,
        binding: binding,
      );

  @override
  bool operator ==(Object other) =>
      other is MapLibreSurface &&
      other.styleString == styleString &&
      other.rotateGesturesEnabled == rotateGesturesEnabled &&
      other.tiltGesturesEnabled == tiltGesturesEnabled &&
      other.compassEnabled == compassEnabled &&
      other.minZoom == minZoom &&
      other.maxZoom == maxZoom;

  @override
  int get hashCode => Object.hash(
    styleString,
    rotateGesturesEnabled,
    tiltGesturesEnabled,
    compassEnabled,
    minZoom,
    maxZoom,
  );
}

/// One mounted map: its controller is here, and nowhere shared.
class _MapLibreHost extends StatefulWidget {
  const _MapLibreHost({
    super.key,
    required this.surface,
    required this.initial,
    required this.binding,
  });

  final MapLibreSurface surface;
  final MapCamera initial;
  final MapBinding binding;

  @override
  State<_MapLibreHost> createState() => _MapLibreHostState();
}

class _MapLibreHostState extends State<_MapLibreHost> {
  MapLibreMapController? _controller;

  @override
  void dispose() {
    // The map is gone with this state: moves made for it are parked again, none reach a dead
    // controller.
    widget.binding.detach();
    _controller = null;
    super.dispose();
  }

  Future<void> _move(
    GeoPoint center,
    double? zoom, {
    required bool animate,
  }) async {
    final controller = _controller;
    if (controller == null) return;
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

  void _created(MapLibreMapController controller) {
    _controller = controller;
    // A move parked until the platform view exists is applied now, without animation.
    widget.binding.attach(_move);
  }

  void _idle() {
    final target = _controller?.cameraPosition?.target;
    if (target == null) return;
    widget.binding.idle(GeoPoint(target.latitude, target.longitude));
  }

  @override
  Widget build(BuildContext context) {
    final surface = widget.surface;
    return MapLibreMap(
      styleString: surface.styleString,
      initialCameraPosition: CameraPosition(
        target: LatLng(
          widget.initial.center.latitude,
          widget.initial.center.longitude,
        ),
        zoom: widget.initial.zoom,
      ),
      trackCameraPosition: true,
      rotateGesturesEnabled: surface.rotateGesturesEnabled,
      tiltGesturesEnabled: surface.tiltGesturesEnabled,
      compassEnabled: surface.compassEnabled,
      minMaxZoomPreference: MinMaxZoomPreference(
        surface.minZoom,
        surface.maxZoom,
      ),
      onMapCreated: _created,
      onCameraMove: (_) => widget.binding.move(),
      onCameraIdle: _idle,
    );
  }
}
