import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:maps/places.dart';

/// The one region pack the app offers: the Douala area, from the style the map uses. The key is
/// the app's own name for it; MapLibre keeps it with the region and telemetry never sees it.
const doualaPack = RegionPackRequest(
  key: 'douala',
  bounds: GeoBounds(GeoPoint(3.98, 9.62), GeoPoint(4.14, 9.85)),
  styleUrl: mapStyleUrl,
  minZoom: 10,
  maxZoom: 13,
);
