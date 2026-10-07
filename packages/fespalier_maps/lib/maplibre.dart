/// The MapLibre surface of the pin picker (since 0.12.0): the one library of this package that
/// imports `maplibre_gl`, so an app that only uses the pure model never links a map.
///
/// Nothing here runs in a widget test (a platform view cannot render there): tests use
/// `FakeMapSurface` from `package:fespalier_maps/testing.dart`.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'fespalier_maps.dart';

/// A [MapSurface] over `MapLibreMap`.
///
/// One surface can be reused by several pickers, one after the other or stacked (a pickup picker
/// that pushes a drop-off picker): each mounted map keeps its own controller, pending move and
/// callbacks, [moveTo] reaches the one mounted last, and when that one goes the one under it is
/// the target again. `MapLibreMap` captures its camera callbacks once, when the platform view is
/// created; the ones given to it here read the latest callbacks of the picker that owns the map.
/// It listens to nothing: the camera events are the widget's own callbacks. The map is a platform
/// view and needs a device to be seen.
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

  /// The mounted maps, in the order they were mounted.
  final List<_SurfaceHostState> _hosts = [];

  @override
  Widget build(
    BuildContext context,
    MapCamera initial, {
    required void Function(GeoPoint center) onIdle,
    required VoidCallback onMove,
  }) => _SurfaceHost(
    surface: this,
    initial: initial,
    onIdle: onIdle,
    onMove: onMove,
  );

  @override
  Future<void> moveTo(GeoPoint center, {double? zoom}) async {
    if (_hosts.isEmpty) return;
    await _hosts.last.moveTo(center, zoom);
  }
}

/// One mounted map: its controller, its pending move and its callbacks live here, so that two
/// pickers on one surface never see each other's map or events.
class _SurfaceHost extends StatefulWidget {
  const _SurfaceHost({
    required this.surface,
    required this.initial,
    required this.onIdle,
    required this.onMove,
  });

  final MapLibreSurface surface;
  final MapCamera initial;
  final void Function(GeoPoint center) onIdle;
  final VoidCallback onMove;

  @override
  State<_SurfaceHost> createState() => _SurfaceHostState();
}

class _SurfaceHostState extends State<_SurfaceHost> {
  MapLibreMapController? _controller;
  GeoPoint? _pending;
  double? _pendingZoom;

  @override
  void initState() {
    super.initState();
    widget.surface._hosts.add(this);
  }

  @override
  void dispose() {
    widget.surface._hosts.remove(this);
    _controller = null;
    _pending = null;
    super.dispose();
  }

  Future<void> moveTo(GeoPoint center, double? zoom) async {
    final controller = _controller;
    if (controller == null) {
      // The platform view is not up yet: applied by onMapCreated.
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

  void _created(MapLibreMapController controller) {
    _controller = controller;
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      unawaited(_apply(controller, pending, _pendingZoom, animate: false));
    }
  }

  void _idle() {
    final target = _controller?.cameraPosition?.target;
    if (target == null) return;
    // `widget` is the latest: this closure was captured once, the widget was not.
    widget.onIdle(GeoPoint(target.latitude, target.longitude));
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
      onCameraMove: (_) => widget.onMove(),
      onCameraIdle: _idle,
    );
  }
}
