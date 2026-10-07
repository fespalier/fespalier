/// Fakes for testing a pin picker with no map, no network and no platform channel (since 0.12.0):
/// `FakeMapSurface`, `FakeGeocoder` and `FakePositionSource`. The MapLibre and geolocator classes
/// (`maplibre.dart`, `geolocator.dart`) are constructed only by the app, never by a test.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'fespalier_maps.dart';

/// The key of the box a [FakeMapSurface] builds.
const Key fakeMapKey = ValueKey<String>('fespalier_maps.fake_map');

/// A [MapSurface] that is a box. Like the real map it keeps the camera callbacks of the build that
/// mounted it, and like [MapLibreSurface] it can have several maps mounted at once (a picker
/// pushed over a picker): the test's [startMove], [idleAt] and [moveTo] reach the one mounted
/// last, and the one under it again when that one goes. The test plays the map: [startMove] and
/// [idleAt] are what a real map reports, and [moves] is what the pickers asked of it.
class FakeMapSurface extends MapSurface {
  /// A fake. With [idleOnMove], [moveTo] ends with an idle event at the point it was given, the
  /// way a real map comes to rest after an animation.
  FakeMapSurface({this.idleOnMove = false});

  /// Whether [moveTo] reports an idle event at the new centre.
  final bool idleOnMove;

  /// The moves the pickers asked for, in order.
  final List<({GeoPoint center, double? zoom})> moves = [];

  /// The camera the last map was built with, or null before one was.
  MapCamera? shown;

  final List<_FakeMapState> _mounted = [];

  /// How many maps are mounted now.
  int get mountedCount => _mounted.length;

  @override
  Widget build(
    BuildContext context,
    MapCamera initial, {
    required void Function(GeoPoint center) onIdle,
    required VoidCallback onMove,
  }) {
    shown = initial;
    return _FakeMap(surface: this, onIdle: onIdle, onMove: onMove);
  }

  /// The camera of the map mounted last starts to move (a drag).
  void startMove() {
    if (_mounted.isNotEmpty) _mounted.last.onMove();
  }

  /// The camera of the map mounted last comes to rest with [center] under the pin.
  void idleAt(GeoPoint center) {
    if (_mounted.isNotEmpty) _mounted.last.onIdle(center);
  }

  @override
  Future<void> moveTo(GeoPoint center, {double? zoom}) async {
    moves.add((center: center, zoom: zoom));
    if (idleOnMove) idleAt(center);
  }
}

class _FakeMap extends StatefulWidget {
  const _FakeMap({
    required this.surface,
    required this.onIdle,
    required this.onMove,
  });

  final FakeMapSurface surface;
  final void Function(GeoPoint center) onIdle;
  final VoidCallback onMove;

  @override
  State<_FakeMap> createState() => _FakeMapState();
}

class _FakeMapState extends State<_FakeMap> {
  // Captured once, as MapLibreMap does when its platform view is created.
  late final void Function(GeoPoint center) onIdle;
  late final VoidCallback onMove;

  @override
  void initState() {
    super.initState();
    onIdle = widget.onIdle;
    onMove = widget.onMove;
    widget.surface._mounted.add(this);
  }

  @override
  void dispose() {
    widget.surface._mounted.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: fakeMapKey);
}

/// One call a [FakeGeocoder] received, held until the test completes it.
final class FakeGeocoderCall<T> {
  FakeGeocoderCall._(this.argument);

  /// The query (a search) or the [GeoPoint] (a reverse).
  final Object argument;

  final Completer<T> _completer = Completer<T>();

  /// Whether [complete] or [fail] was called.
  bool get isCompleted => _completer.isCompleted;

  /// Answers the call.
  void complete(T answer) => _completer.complete(answer);

  /// Makes the call throw.
  void fail([Object error = 'geocoder failed']) =>
      _completer.completeError(error);
}

/// A [Geocoder] with answers from tables, or held until the test completes each call, which is
/// how a test orders two answers to prove that a stale one is dropped.
class FakeGeocoder implements Geocoder {
  /// A fake. [places] answers a search by its exact query; [reverseAnswer] answers a reverse
  /// (null: no name there). With [hold], every call waits for [searchCalls] or [reverseCalls]
  /// to be completed by the test.
  FakeGeocoder({this.places = const {}, this.reverseAnswer, this.hold = false});

  /// Answers by exact query; a query not in it answers no places.
  Map<String, List<PlaceGuess>> places;

  /// Answers a reverse; null answers "nothing here".
  PlaceGuess? Function(GeoPoint point)? reverseAnswer;

  /// Whether calls wait for the test.
  final bool hold;

  /// When set, every call throws it (a refused or offline geocoder).
  Object? error;

  /// The searches received, in order.
  final List<FakeGeocoderCall<List<PlaceGuess>>> searchCalls = [];

  /// The reverse geocodes received, in order.
  final List<FakeGeocoderCall<PlaceGuess?>> reverseCalls = [];

  /// The `near` and `locale` of each search, in order.
  final List<({GeoPoint? near, String? locale})> searchContext = [];

  /// The `locale` of each reverse, in order.
  final List<String?> reverseLocales = [];

  @override
  Future<List<PlaceGuess>> search(
    String query, {
    GeoPoint? near,
    String? locale,
  }) {
    final call = FakeGeocoderCall<List<PlaceGuess>>._(query);
    searchCalls.add(call);
    searchContext.add((near: near, locale: locale));
    final failure = error;
    if (failure != null) return Future.error(failure);
    if (!hold) call.complete(places[query] ?? const []);
    return call._completer.future;
  }

  @override
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale}) {
    final call = FakeGeocoderCall<PlaceGuess?>._(point);
    reverseCalls.add(call);
    reverseLocales.add(locale);
    final failure = error;
    if (failure != null) return Future.error(failure);
    if (!hold) call.complete(reverseAnswer?.call(point));
    return call._completer.future;
  }
}

/// A [PositionSource] that answers with [answer], or waits for [release].
class FakePositionSource implements PositionSource {
  /// A fake answering [answer]; with [hold] it waits for [release] first.
  FakePositionSource(this.answer, {this.hold = false});

  /// What [current] answers.
  PositionFix answer;

  /// Whether [current] waits for [release].
  final bool hold;

  /// How many times [current] was called.
  int calls = 0;

  final List<Completer<PositionFix>> _waiting = [];

  @override
  Future<PositionFix> current() {
    calls++;
    if (!hold) return Future.value(answer);
    final completer = Completer<PositionFix>();
    _waiting.add(completer);
    return completer.future;
  }

  /// Answers every waiting call with [fix], or [answer].
  void release([PositionFix? fix]) {
    final waiting = List.of(_waiting);
    _waiting.clear();
    for (final completer in waiting) {
      completer.complete(fix ?? answer);
    }
  }
}
