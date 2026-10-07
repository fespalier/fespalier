/// The MapLibre side of the package (since 0.13.0): the surface of the pin picker and the offline
/// database of the region packs. The one library of this package that imports `maplibre_gl`, so
/// an app that only uses the pure model never links a map.
///
/// Nothing here runs in a widget test (a platform view cannot render there, and the offline
/// calls are platform channels): tests use `FakeMapSurface` and `FakeOfflineTiles` from
/// `package:fespalier_maps/testing.dart`.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import 'fespalier_maps.dart';

/// A [MapSurface] over `MapLibreMap`: configuration only, with value equality.
///
/// It holds no state about a picker, so one surface can be shared by any number of them, stacked
/// (a pickup picker that pushes a drop-off picker) or in turn: each map it builds belongs to the
/// [MapBinding] it was built for, keeps its own controller, and receives only the moves that
/// binding makes. `MapLibreMap` captures its camera callbacks once, when the platform view is
/// created; the ones given to it here call the binding, which is the same for the map's life. It
/// listens to nothing. The map is a platform view and needs a device to be seen.
final class MapLibreSurface extends MapSurface {
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
  // The camera of the first build only: `MapLibreMap` ignores a later one, and this host is
  // updated in place when the surface's options change.
  late final MapCamera _initial = widget.initial;

  @override
  void dispose() {
    // The map is gone with this state: moves made for it are parked again, none reach a dead
    // controller. Only if this map is still the attached one (see [MapBinding.detach]).
    widget.binding.detach(_move);
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
        target: LatLng(_initial.center.latitude, _initial.center.longitude),
        zoom: _initial.zoom,
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

/// The key under which a region's metadata holds the pack's key.
const String _keyField = 'fespalier_maps.key';

/// An [OfflineTiles] over MapLibre's offline database (`downloadOfflineRegion` and its siblings
/// of `maplibre_gl`, 0.26.0 and 0.27.x alike). Install it for `TilePacks`:
///
/// ```dart
/// ProviderScope(
///   overrides: [offlineTiles.overrideWithValue(const MapLibreOfflineTiles())],
///   child: const MyApp(),
/// )
/// ```
///
/// Android and iOS only: on the web every download throws an [UnsupportedError], which the packs
/// report as [PackFailure.unsupported], and the list of regions is empty. A pack is a region of
/// MapLibre's database with the pack's key in its metadata; a region something else made has no
/// key and is not listed. It listens to nothing: the plugin's download events reach the callback
/// `download` is given.
///
/// A platform channel needs a device: a widget test uses `FakeOfflineTiles`.
final class MapLibreOfflineTiles implements OfflineTiles {
  /// The offline database of this app. [onDiskBytes] answers [databaseBytes]: `maplibre_gl`
  /// 0.27 can say where the file is (`getOfflineDatabasePath`) and 0.26 cannot, so this package,
  /// which builds on both, leaves the size of the file to the app (a recipe in the skill reads
  /// it with `dart:io`).
  const MapLibreOfflineTiles({this.onDiskBytes});

  /// How the app measures the offline database file, or null for "unknown".
  final Future<int?> Function()? onDiskBytes;

  @override
  Future<List<StoredRegion>> regions() async {
    if (kIsWeb) return const [];
    return [for (final region in await ml.getListOfRegions()) _stored(region)];
  }

  @override
  Future<StoredRegion> download(
    RegionPackRequest request,
    void Function(DownloadEvent event) onEvent,
  ) async {
    if (kIsWeb) {
      throw UnsupportedError('Offline regions are not available on the web.');
    }
    final region = await ml.downloadOfflineRegion(
      ml.OfflineRegionDefinition(
        bounds: ml.LatLngBounds(
          southwest: ml.LatLng(
            request.bounds.southwest.latitude,
            request.bounds.southwest.longitude,
          ),
          northeast: ml.LatLng(
            request.bounds.northeast.latitude,
            request.bounds.northeast.longitude,
          ),
        ),
        mapStyleUrl: request.styleUrl,
        minZoom: request.minZoom,
        maxZoom: request.maxZoom,
      ),
      metadata: <String, dynamic>{_keyField: request.key},
      onEvent: (ml.DownloadRegionStatus event) => onEvent(_event(event)),
    );
    return _stored(region);
  }

  @override
  Future<void> pause(int id) => ml.pauseOfflineRegionDownload(id);

  @override
  Future<void> resume(int id) => ml.resumeOfflineRegionDownload(id);

  @override
  Future<void> delete(int id) async {
    await ml.deleteOfflineRegion(id);
  }

  @override
  Future<RegionStatus> status(int id) async {
    final status = await ml.getOfflineRegionStatus(id);
    return RegionStatus(
      progress: status.downloadProgress,
      completedResources: status.completedResourceCount,
      requiredResources: status.requiredResourceCount,
      bytes: status.completedResourceSize,
      isComplete: status.isComplete,
    );
  }

  @override
  Future<int?> databaseBytes() async => onDiskBytes?.call();
}

DownloadEvent _event(ml.DownloadRegionStatus event) => switch (event) {
  ml.InProgress() => DownloadProgress(
    progress: event.progress,
    completedResources: event.completedResourceCount,
    requiredResources: event.requiredResourceCount,
    bytes: event.completedResourceSize,
  ),
  ml.Success() => const DownloadFinished(),
  ml.Error() => DownloadFailed(PackFailure.of(event.cause)),
  _ => const DownloadFailed(PackFailure.other),
};

StoredRegion _stored(ml.OfflineRegion region) {
  // 0.26.0 hands a region made elsewhere a null here, in a field typed non-null.
  // ignore: unnecessary_nullable_for_final_variable_declarations
  final Object? metadata = region.metadata;
  final key = metadata is Map ? metadata[_keyField] : null;
  if (key is! String || key.isEmpty) return StoredRegion(id: region.id);
  final definition = region.definition;
  return StoredRegion(
    id: region.id,
    request: RegionPackRequest(
      key: key,
      bounds: GeoBounds(
        GeoPoint(
          definition.bounds.southwest.latitude,
          definition.bounds.southwest.longitude,
        ),
        GeoPoint(
          definition.bounds.northeast.latitude,
          definition.bounds.northeast.longitude,
        ),
      ),
      styleUrl: definition.mapStyleUrl,
      minZoom: definition.minZoom,
      maxZoom: definition.maxZoom,
    ),
  );
}
