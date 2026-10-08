import 'package:fespalier/startup.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/maplibre.dart';

/// The one provider `fespalier_maps` leaves without a default: the offline database. The
/// MapLibre one is `const` and reads nothing until a page asks. A widget test overrides
/// `offlineTiles` with a `FakeOfflineTiles` (startup() does not run in `pumpRouter`).
Future<List<Override>> startup() async => [
  offlineTiles.overrideWithValue(const MapLibreOfflineTiles()),
];
