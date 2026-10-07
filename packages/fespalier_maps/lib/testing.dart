/// Fakes for testing a pin picker with no map, no network and no platform channel (since 0.13.0):
/// `FakeMapSurface`, `FakeGeocoder` and `FakePositionSource`. The MapLibre and geolocator classes
/// (`maplibre.dart`, `geolocator.dart`) are constructed only by the app, never by a test.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'fespalier_maps.dart';

/// The key of the box a [FakeMapSurface] builds.
const Key fakeMapKey = ValueKey<String>('fespalier_maps.fake_map');

/// A [MapSurface] that is a box, and like [MapLibreSurface] it holds no state about a picker:
/// each map it builds is a [FakeMapMount] bound to the picker's [MapBinding], and a move reaches
/// only the mount of the binding that made it. The test plays the map through a mount
/// ([FakeMapMount.startMove], [FakeMapMount.idleAt]) or, for the one mounted last, through the
/// surface's own [startMove] and [idleAt].
class FakeMapSurface extends MapSurface {
  /// A fake. With [idleOnMove], a move ends with an idle event at the point it moved to, on the
  /// mount that moved, the way a real map comes to rest after an animation.
  FakeMapSurface({this.idleOnMove = false});

  /// Whether a move reports an idle event at the new centre.
  final bool idleOnMove;

  /// Every move any mount received, in order.
  final List<({GeoPoint center, double? zoom})> moves = [];

  /// The camera the last map was built with, or null before one was.
  MapCamera? shown;

  /// The maps mounted now, in the order they were mounted.
  final List<FakeMapMount> mounts = [];

  /// How many maps are mounted now.
  int get mountedCount => mounts.length;

  /// Mounts a fake map for [binding] without a widget, the way [build] does when its widget is
  /// mounted: for a test of a picker's model alone.
  FakeMapMount mount(MapBinding binding) {
    final mount = FakeMapMount._(this, binding);
    mounts.add(mount);
    binding.attach(mount._move);
    return mount;
  }

  @override
  Widget build(BuildContext context, MapCamera initial, MapBinding binding) {
    shown = initial;
    return _FakeMap(
      key: ValueKey<MapBinding>(binding),
      surface: this,
      binding: binding,
    );
  }

  /// The camera of the map mounted last starts to move (a drag).
  void startMove() {
    if (mounts.isNotEmpty) mounts.last.startMove();
  }

  /// The camera of the map mounted last comes to rest with [center] under the pin.
  void idleAt(GeoPoint center) {
    if (mounts.isNotEmpty) mounts.last.idleAt(center);
  }
}

/// One fake map, bound to one picker.
final class FakeMapMount {
  FakeMapMount._(this.surface, this.binding);

  /// The surface that built it.
  final FakeMapSurface surface;

  /// The picker's binding.
  final MapBinding binding;

  /// The moves this map received, in order.
  final List<({GeoPoint center, double? zoom})> moves = [];

  /// For each move, whether it animated (a parked move applied on arrival does not).
  final List<bool> animated = [];

  /// The camera starts to move (a drag).
  void startMove() => binding.move();

  /// The camera comes to rest with [center] under the pin.
  void idleAt(GeoPoint center) => binding.idle(center);

  /// Takes the map away, as unmounting its widget does: the binding is detached.
  void unmount() {
    surface.mounts.remove(this);
    binding.detach();
  }

  Future<void> _move(
    GeoPoint center,
    double? zoom, {
    required bool animate,
  }) async {
    moves.add((center: center, zoom: zoom));
    animated.add(animate);
    surface.moves.add((center: center, zoom: zoom));
    if (surface.idleOnMove) idleAt(center);
  }
}

class _FakeMap extends StatefulWidget {
  const _FakeMap({super.key, required this.surface, required this.binding});

  final FakeMapSurface surface;
  final MapBinding binding;

  @override
  State<_FakeMap> createState() => _FakeMapState();
}

class _FakeMapState extends State<_FakeMap> {
  late final FakeMapMount _mount;

  @override
  void initState() {
    super.initState();
    _mount = widget.surface.mount(widget.binding);
  }

  @override
  void dispose() {
    _mount.unmount();
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
