# Geocoders for the pin picker

`fespalier_maps` has **no geocoder of its own**: no network code, no `http` dependency. A `Geocoder` is two methods, and
the network, the provider and its terms of use are the app's. Three recipes are compiled below (Nominatim, Photon, an app
backend); they are recipes, not package code, for the reason `fespalier_flags` keeps vendor sources as recipes: one app
wants OSM's public servers, another its own instance, a third its own API.

```dart
abstract interface class Geocoder {
  Future<List<PlaceGuess>> search(String query, {GeoPoint? near, String? locale});
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale});
}
```

## The contract

- **Throw on failure** (a refused request, a bad status, a body that is not what you expect). The picker turns it into
  `PinSearch.failed` / `PinGuess.failed` and drops it: it never keeps or shows the error's text. Put **no query and no
  coordinate in the exception** either: a message such as `geocoder answered 429` is the shape to copy.
- **`search` returns best first**, biased towards `near` (the pin) when the provider can, labelled in `locale` (a BCP 47 tag
  such as `fr` or `pt-BR`; null means the provider's default).
- **`reverse` returns null when nothing is there**; that is an answer, and the picker will not ask the same point again.
- **Both are called from the UI isolate and must not block**: do the HTTP, parse a small body, return.
- **A label is a guess.** Whatever the provider's `display_name` is, the picker shows it as a guess; keep `label` short
  (a street, a place) and put the long form in `detail`.
- **Each reverse is one request per rest of the map**, and a person can pan a lot. Rate limits are the provider's, not the
  picker's (no debounce timer): a public server is for light use, which is why an app with real traffic runs its own
  instance or uses a paid one.

## Nominatim

OpenStreetMap's geocoder. Its public server's [usage policy](https://operations.osmfoundation.org/policies/nominatim/)
(read it before shipping, it changes): at most one request per second, "no heavy uses"; a valid `User-Agent` or `Referer`
that **identifies your application** (a library's default is not enough); **no auto-complete search** (which is why the
picker submits a query instead of searching per keystroke); cache results; display the OpenStreetMap attribution. A
browser cannot set `User-Agent`, so on the web the `Referer` identifies the app, and the optional `email` parameter is the
documented way to leave a contact. For anything beyond light use, run your own instance.

```yaml
# pubspec.yaml dependencies
  http: ^1.2.0
```

```dart
// lib/places/nominatim.dart
import 'dart:convert';

import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:http/http.dart' as http;

class NominatimGeocoder implements Geocoder {
  NominatimGeocoder(
    this.client, {
    required this.userAgent,
    this.baseUrl = 'https://nominatim.openstreetmap.org',
    this.email,
  });

  final http.Client client;

  /// Identifies the app, e.g. 'my-shop-app/1.4 (contact@example.com)'. Not a library default.
  final String userAgent;
  final String baseUrl;
  final String? email;

  Future<Object?> _get(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: {
      'format': 'jsonv2',
      if (email != null) 'email': email!,
      ...query,
    });
    final response = await client.get(uri, headers: {'User-Agent': userAgent});
    if (response.statusCode != 200) {
      // The status only: the URL holds the query and the coordinate.
      throw StateError('geocoder answered ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  PlaceGuess? _guess(Object? item) {
    if (item is! Map<String, Object?>) return null;
    final lat = double.tryParse('${item['lat']}');
    final lon = double.tryParse('${item['lon']}');
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
    final full = item['display_name'];
    final name = item['name'];
    final label = name is String && name.isNotEmpty ? name : (full is String ? full.split(',').first : '');
    if (label.isEmpty) return null;
    return PlaceGuess(GeoPoint(lat, lon), label, detail: full is String ? full : null);
  }

  @override
  Future<List<PlaceGuess>> search(String query, {GeoPoint? near, String? locale}) async {
    final body = await _get('/search', {
      'q': query,
      'limit': '5',
      if (locale != null) 'accept-language': locale,
      // A preference, not a limit: bounded=0 is the default, so places outside still answer.
      if (near != null)
        'viewbox': '${near.longitude - 0.5},${near.latitude + 0.5},${near.longitude + 0.5},${near.latitude - 0.5}',
    });
    if (body is! List<Object?>) throw StateError('geocoder answered an unexpected body');
    return [for (final item in body) ?_guess(item)];
  }

  @override
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale}) async {
    final body = await _get('/reverse', {
      'lat': '${point.latitude}',
      'lon': '${point.longitude}',
      'zoom': '18',
      if (locale != null) 'accept-language': locale,
    });
    // "Unable to geocode" arrives as {"error": ...} with status 200: nothing there.
    return body is Map<String, Object?> && body['error'] == null ? _guess(body) : null;
  }
}
```

Show the attribution the policy asks for somewhere the person can read it (a line under the map, or `MapLibreSurface`'s
own attribution button for the tiles' source: the geocoder's data is OSM's even when the tiles are not).

## Photon

[Photon](https://github.com/komoot/photon) is an OSM geocoder built for search as you type, with its own public server
(`photon.komoot.io`) whose stated terms are "a reasonable limit" of requests, with no availability guarantee, and a
recommendation to run your own instance for volume. `/api?q=` searches (location bias with `lat` and `lon`), `/reverse`
takes mandatory `lat` and `lon`, `lang` sets the response language, and the answer is GeoJSON with coordinates as
`[longitude, latitude]` and `name`, `street`, `housenumber`, `city`, `country` among the properties. Check which `lang`
values your instance accepts: a tag it does not have may be refused, so pass the language part (`fr`, not `fr-CM`) or none.

```dart
// lib/places/photon.dart
import 'dart:convert';

import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:http/http.dart' as http;

class PhotonGeocoder implements Geocoder {
  PhotonGeocoder(this.client, {this.baseUrl = 'https://photon.komoot.io'});

  final http.Client client;
  final String baseUrl;

  Future<List<PlaceGuess>> _features(String path, Map<String, String> query) async {
    final response = await client.get(Uri.parse('$baseUrl$path').replace(queryParameters: query));
    if (response.statusCode != 200) {
      throw StateError('geocoder answered ${response.statusCode}');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final features = body is Map<String, Object?> ? body['features'] : null;
    if (features is! List<Object?>) throw StateError('geocoder answered an unexpected body');
    return [for (final feature in features) ?_guess(feature)];
  }

  PlaceGuess? _guess(Object? feature) {
    if (feature is! Map<String, Object?>) return null;
    final geometry = feature['geometry'];
    final properties = feature['properties'];
    if (geometry is! Map<String, Object?> || properties is! Map<String, Object?>) return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List<Object?> || coordinates.length < 2) return null;
    final lon = coordinates[0];
    final lat = coordinates[1];
    if (lon is! num || lat is! num || lat.abs() > 90 || lon.abs() > 180) return null;
    String? part(String key) {
      final value = properties[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final street = part('street');
    final house = part('housenumber');
    final label = part('name') ?? (street == null ? null : (house == null ? street : '$street $house'));
    if (label == null) return null;
    final detail = [part('city'), part('state'), part('country')].whereType<String>().join(', ');
    return PlaceGuess(GeoPoint(lat.toDouble(), lon.toDouble()), label, detail: detail.isEmpty ? null : detail);
  }

  @override
  Future<List<PlaceGuess>> search(String query, {GeoPoint? near, String? locale}) => _features('/api', {
    'q': query,
    'limit': '5',
    if (near != null) ...{'lat': '${near.latitude}', 'lon': '${near.longitude}'},
    if (locale != null) 'lang': locale.split(RegExp('[-_]')).first,
  });

  @override
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale}) async {
    final found = await _features('/reverse', {
      'lat': '${point.latitude}',
      'lon': '${point.longitude}',
      if (locale != null) 'lang': locale.split(RegExp('[-_]')).first,
    });
    return found.isEmpty ? null : found.first;
  }
}
```

## Your own backend

The usual choice for an app with traffic, a paid provider (Google, Mapbox, HERE, Geoapify, ...) or a self-hosted
Nominatim or Photon: the app's server calls it, so the **provider's key stays on the server** (a key in a build is public)
and the app speaks one small API. The recipe is the same two methods over the app's own client; here the app's API is a
typed `PlacesApi` the app already has.

```dart
// lib/places/backend_geocoder.dart
import 'package:fespalier_maps/fespalier_maps.dart';

typedef PlaceRow = ({double lat, double lng, String label, String? detail});

/// The app's own API client for its places endpoint (a Dio call, a generated client, ...).
abstract interface class PlacesApi {
  Future<List<PlaceRow>> search(String query, {double? nearLat, double? nearLng, String? locale});
  Future<PlaceRow?> reverse(double lat, double lng, {String? locale});
}

class BackendGeocoder implements Geocoder {
  const BackendGeocoder(this.api);

  final PlacesApi api;

  PlaceGuess _guess(PlaceRow row) => PlaceGuess(GeoPoint(row.lat, row.lng), row.label, detail: row.detail);

  @override
  Future<List<PlaceGuess>> search(String query, {GeoPoint? near, String? locale}) async => [
    for (final row in await api.search(query, nearLat: near?.latitude, nearLng: near?.longitude, locale: locale))
      _guess(row),
  ];

  @override
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale}) async {
    final row = await api.reverse(point.latitude, point.longitude, locale: locale);
    return row == null ? null : _guess(row);
  }
}
```

A backend that rate-limits per user also answers the "each rest of the map is a request" cost: the picker asks at most once
per rest and never for a point it already has an answer for.

## Testing a geocoder

A recipe is plain Dart over an `http.Client`: test it with `package:http/testing.dart`'s `MockClient` (no network), and test
the page with `FakeGeocoder` from `package:fespalier_maps/testing.dart`
([`pin-picker.md`](pin-picker.md)). A test of a geocoder should assert that a failure's exception message holds neither the
query nor a coordinate.
