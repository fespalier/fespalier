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
/// It serves one picker at a time and may be reused by the next one (a top-level `final` is
/// fine): it holds the map's controller, which is how [moveTo] reaches the map, and forgets it
/// when its map is disposed. `MapLibreMap` captures its camera callbacks once, when the platform
/// view is created; the ones given to it here are forwarders that read the latest callbacks of
/// the last [build]. It listens to nothing: the camera events are the widget's own callbacks.
/// The map is a platform view and needs a device to be seen.
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
  void Function(GeoPoint center)? _onIdle;
  VoidCallback? _onMove;
  Object? _host;

  void _forwardMove() => _onMove?.call();

  void _forwardIdle() {
    final target = _controller?.cameraPosition?.target;
    if (target == null) return;
    _onIdle?.call(GeoPoint(target.latitude, target.longitude));
  }

  @override
  Widget build(
    BuildContext context,
    MapCamera initial, {
    required void Function(GeoPoint center) onIdle,
    required VoidCallback onMove,
  }) {
    _onIdle = onIdle;
    _onMove = onMove;
    return _SurfaceHost(
      key: ValueKey<Object>(this),
      onAttach: (host) => _host = host,
      onDetach: (host) {
        // Only the host that is still the current one forgets: a new page's map may already be up.
        if (!identical(_host, host)) return;
        _host = null;
        _controller = null;
        _pending = null;
      },
      child: _map(initial),
    );
  }

  Widget _map(MapCamera initial) {
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
      onCameraMove: (_) => _forwardMove(),
      onCameraIdle: _forwardIdle,
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

/// Tells the surface when its map is gone, so a reused surface does not talk to a dead controller.
class _SurfaceHost extends StatefulWidget {
  const _SurfaceHost({
    super.key,
    required this.onAttach,
    required this.onDetach,
    required this.child,
  });

  final void Function(Object host) onAttach;
  final void Function(Object host) onDetach;
  final Widget child;

  @override
  State<_SurfaceHost> createState() => _SurfaceHostState();
}

class _SurfaceHostState extends State<_SurfaceHost> {
  @override
  void initState() {
    super.initState();
    widget.onAttach(this);
  }

  @override
  void dispose() {
    widget.onDetach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
