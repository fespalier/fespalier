/// Maps for fespalier (since 0.12.0): a pin picker that returns a place.
///
/// The pin is fixed at the centre and the map moves under it. This library has no MapLibre and no
/// geolocator in it: the map is a [MapSurface] (`package:fespalier_maps/maplibre.dart`), the
/// device position a [PositionSource] (`package:fespalier_maps/geolocator.dart`), the geocoder
/// the app's own [Geocoder] (recipes in the skill), and `package:fespalier_maps/testing.dart`
/// has a fake of each.
library;

export 'src/geo.dart';
export 'src/pin_model.dart';
export 'src/pin_picker.dart';
export 'src/ports.dart';
export 'src/telemetry.dart' show MapsTelemetry;
export 'src/tiles.dart' show tileCount;
