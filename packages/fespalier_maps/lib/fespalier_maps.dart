/// Maps for fespalier (since 0.13.0): a pin picker that returns a place, and offline region
/// packs.
///
/// The pin is fixed at the centre and the map moves under it. This library has no MapLibre and no
/// geolocator in it: the map is a [MapSurface] (`package:fespalier_maps/maplibre.dart`), the
/// device position a [PositionSource] (`package:fespalier_maps/geolocator.dart`), the geocoder
/// the app's own [Geocoder] (recipes in the skill), and `package:fespalier_maps/testing.dart`
/// has a fake of each. The offline packs are `TilePacks` over an [OfflineTiles] (MapLibre's is in
/// `maplibre.dart`).
library;

export 'src/geo.dart';
export 'src/offline/port.dart';
export 'src/offline/request.dart';
export 'src/offline/status.dart';
export 'src/offline/tile_packs.dart';
export 'src/pin_model.dart';
export 'src/pin_picker.dart';
export 'src/ports.dart';
export 'src/telemetry.dart' show MapsTelemetry;
export 'src/tiles.dart' show tileCount;
