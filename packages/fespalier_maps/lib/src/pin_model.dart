import 'dart:async';

import 'package:fespalier/fespalier.dart' show TelemetryOutcome;
import 'package:flutter/foundation.dart';

import 'geo.dart';
import 'ports.dart';
import 'telemetry.dart';

/// What the search field of a [PinPicker] is told: the query, the answers and how to act. A
/// snapshot, rebuilt on every change.
@immutable
final class PinSearch {
  /// A snapshot; the callbacks belong to the picker.
  const PinSearch({
    required this.query,
    required this.results,
    required this.busy,
    required this.failed,
    required this.submit,
    required this.pick,
    required this.useMyLocation,
    required this.clear,
  });

  /// The last query sent (empty before the first search).
  final String query;

  /// The places the geocoder answered with, best first; empty before a search, after a pick and
  /// after [clear].
  final List<PlaceGuess> results;

  /// Whether a search is waiting for its answer.
  final bool busy;

  /// Whether the last search threw (the text of the error is never kept).
  final bool failed;

  /// Sends a query: from the keyboard's "search" action, never per keystroke. An empty query
  /// clears the results.
  final void Function(String query) submit;

  /// Moves the map under the pin to one of [results]; the label shows as the guess for it.
  final void Function(PlaceGuess place) pick;

  /// Asks the position source again and moves the map to the answer.
  final Future<void> Function() useMyLocation;

  /// Drops the results and the query.
  final VoidCallback clear;
}

/// What the guess card of a [PinPicker] is told: where the pin is and what the geocoder thinks
/// is there. A snapshot, rebuilt on every change.
@immutable
final class PinGuess {
  /// A snapshot.
  const PinGuess({
    required this.center,
    required this.guess,
    required this.guessing,
    required this.failed,
    required this.moving,
    required this.fix,
  });

  /// The point under the pin; null until the person has chosen one (the map's first position
  /// before a fix is not a choice).
  final GeoPoint? center;

  /// The geocoder's guess for exactly [center], or null while [guessing], after a failure or
  /// where it knows nothing. Show it as a guess: it can be wrong.
  final PlaceGuess? guess;

  /// Whether a reverse geocode for [center] is in flight.
  final bool guessing;

  /// Whether the last reverse geocode threw.
  final bool failed;

  /// Whether the map is moving under the pin ([center] is where it was).
  final bool moving;

  /// The last answer of the position source, or null when it was not asked (or is still
  /// being): render [Denied], [ServiceOff] and [Unavailable] as a hint, never as an error page.
  final PositionFix? fix;
}

/// The state and the decisions of a pin picker, with no widget in it, so that it is tested with
/// fakes and no map.
///
/// The pin is fixed and the map moves under it. The model learns where it is from [onIdle]
/// (an event, not a timer), asks the geocoder for a name of that point, and drops any answer
/// that a newer request has overtaken (a sequence number, never a debounce). It starts no timer
/// and listens to nothing. Telemetry (`MapsTelemetry`) carries kinds and results, never a place.
class PinPickerModel extends ChangeNotifier {
  /// A model over [map] and [geocoder]. With an [initial] camera the picker starts there and
  /// [position] is not asked; without one, [position] (when given) seeds the map once.
  PinPickerModel({
    required this.map,
    required this.geocoder,
    this.position,
    this.initial,
    this.locale,
    this.focusZoom = 16,
  }) : _chosen = initial != null,
       _center = initial?.center,
       _awaitingFix = initial == null && position != null;

  /// The map under the pin.
  final MapSurface map;

  /// The geocoder. Assigned again by [PinPicker] on every build, so a new geocoder or locale
  /// takes effect without a new model: the map captured this model's callbacks once.
  Geocoder geocoder;

  /// Where the device is, or null for a picker that never asks.
  PositionSource? position;

  /// Where the map starts (an existing place being edited), or null for [MapCamera.world].
  final MapCamera? initial;

  /// The BCP 47 tag the geocoder is asked to label in.
  String? locale;

  /// The zoom the map moves to for a fix or a picked result.
  double focusZoom;

  /// What the map shows first.
  MapCamera get initialCamera => initial ?? MapCamera.world;

  GeoPoint? _center;
  bool _chosen;
  bool _awaitingFix;
  bool _panned = false;
  bool _moving = false;
  bool _disposed = false;

  PlaceGuess? _guess;
  GeoPoint? _guessFor;
  bool _guessing = false;
  bool _guessFailed = false;
  int _reverseSeq = 0;
  bool _reverseInFlight = false;
  int _inFlightSeq = -1;
  GeoPoint? _inFlightPoint;
  GeoPoint? _queued;

  String _query = '';
  List<PlaceGuess> _results = const [];
  bool _searching = false;
  bool _searchFailed = false;
  int _searchSeq = 0;

  PositionFix? _fix;
  int _locateSeq = 0;

  /// The point under the pin, or null until one is chosen.
  GeoPoint? get center => _center;

  /// Whether [confirm] would return a place: the pin has a point and the map is at rest.
  bool get canConfirm => _center != null && !_moving;

  /// The search field's snapshot.
  PinSearch get search => PinSearch(
    query: _query,
    results: _results,
    busy: _searching,
    failed: _searchFailed,
    submit: (q) => unawaited(submit(q)),
    pick: (place) => unawaited(pick(place)),
    useMyLocation: useMyLocation,
    clear: clear,
  );

  /// The guess card's snapshot.
  PinGuess get guessState => PinGuess(
    center: _center,
    guess: _guessFor == _center ? _guess : null,
    guessing: _guessing,
    failed: _guessFailed,
    moving: _moving,
    fix: _fix,
  );

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }

  /// Asks the position source once, when there is one and no [initial] place: the fix moves the
  /// map. Call it once, after the first frame.
  Future<void> seed() async {
    if (!_awaitingFix) return;
    await _locate(seed: true);
    notifyListeners();
  }

  /// Asks the position source again, for the "use my location" button; the map moves to a fix.
  Future<void> useMyLocation() async {
    if (position == null) return;
    _awaitingFix = false;
    _panned = false;
    await _locate(seed: false);
  }

  Future<void> _locate({required bool seed}) async {
    final source = position;
    if (source == null) return;
    final seq = ++_locateSeq;
    final token = mapsBegin(MapsTelemetry.locate);
    PositionFix answer;
    try {
      answer = await source.current();
    } catch (_) {
      answer = const Unavailable();
    }
    if (_disposed || seq != _locateSeq) {
      mapsFinish(
        token,
        MapsTelemetry.resultStale,
        outcome: TelemetryOutcome.superseded,
      );
      return;
    }
    // From here the map's own rests count: the move to a fix ends in an idle event that must be
    // heard, possibly before the move's Future completes.
    _awaitingFix = false;
    _fix = answer;
    // The person is panning while the seed arrives: the map is theirs now. Their rest is adopted
    // by [onIdle] whatever the answer was, and a fix never moves the map from under them.
    final yielded = seed && _panned;
    if (yielded) _chosen = true;
    mapsFinish(
      token,
      switch (answer) {
        Fixed() => MapsTelemetry.resultFixed,
        ServiceOff() => MapsTelemetry.resultOff,
        Denied() => MapsTelemetry.resultDenied,
        Unavailable() => MapsTelemetry.resultError,
      },
      outcome: answer is Unavailable
          ? TelemetryOutcome.error
          : TelemetryOutcome.ok,
    );
    notifyListeners();
    if (answer is Fixed && !yielded) await _moveTo(answer.point);
  }

  /// The map started to move under the pin.
  void onMove() {
    if (_awaitingFix) {
      // Remembered, not acted on: the map's own first movements at load are not the person's.
      // The rest that follows decides (see [onIdle]).
      _panned = true;
      return;
    }
    _chosen = true;
    if (_moving) return;
    _moving = true;
    notifyListeners();
  }

  /// The map came to rest with [point] under the pin: ask the geocoder for a name, unless it
  /// already has one for that point (a picked result), and drop every answer still on its way.
  void onIdle(GeoPoint point) {
    if (_awaitingFix && _panned) {
      // A pan that came to rest while the fix is awaited: the person chose a place. The fix, when
      // it arrives, is stale; the pan is adopted, whatever the answer.
      _awaitingFix = false;
      _locateSeq++;
      _chosen = true;
    }
    if (_awaitingFix || !_chosen) return;
    _moving = false;
    _center = point;
    final known = _guessFor;
    if (known != null && _near(known, point)) {
      _guessFor = point;
      notifyListeners();
      return;
    }
    _guess = null;
    _guessFor = null;
    _guessing = true;
    _guessFailed = false;
    notifyListeners();
    if (_reverseInFlight) {
      // At most one reverse request at a time. The pin is already being asked about, or the
      // newest rest waits (replacing any older one) for the answer on its way.
      final asking = _inFlightPoint;
      if (asking != null &&
          _inFlightSeq == _reverseSeq &&
          _near(asking, point)) {
        _queued = null;
      } else {
        _queued = point;
      }
      return;
    }
    unawaited(_reverse(point));
  }

  Future<void> _reverse(GeoPoint point) async {
    final seq = ++_reverseSeq;
    _reverseInFlight = true;
    _inFlightSeq = seq;
    _inFlightPoint = point;
    final token = mapsBegin(MapsTelemetry.geocode, {
      MapsTelemetry.direction: MapsTelemetry.directionReverse,
    });
    PlaceGuess? answer;
    var failed = false;
    try {
      answer = await geocoder.reverse(point, locale: locale);
    } catch (_) {
      failed = true;
    }
    _reverseInFlight = false;
    final next = _queued;
    _queued = null;
    if (_disposed || seq != _reverseSeq || next != null) {
      mapsFinish(
        token,
        MapsTelemetry.resultStale,
        outcome: TelemetryOutcome.superseded,
      );
      if (!_disposed && next != null) unawaited(_reverse(next));
      return;
    }
    _guessing = false;
    _guessFailed = failed;
    if (!failed) {
      _guess = answer;
      _guessFor = point;
    }
    mapsFinish(
      token,
      failed
          ? MapsTelemetry.resultError
          : answer == null
          ? MapsTelemetry.resultEmpty
          : MapsTelemetry.resultFound,
      outcome: failed ? TelemetryOutcome.error : TelemetryOutcome.ok,
    );
    notifyListeners();
  }

  /// Sends [query] to the geocoder, biased towards the pin, and keeps the answers in
  /// [search]. A newer submit makes this one's answer stale.
  Future<void> submit(String query) async {
    final text = query.trim();
    final seq = ++_searchSeq;
    _query = text;
    _searchFailed = false;
    if (text.isEmpty) {
      _results = const [];
      _searching = false;
      notifyListeners();
      return;
    }
    _searching = true;
    notifyListeners();
    final token = mapsBegin(MapsTelemetry.geocode, {
      MapsTelemetry.direction: MapsTelemetry.directionSearch,
    });
    List<PlaceGuess> answer = const [];
    var failed = false;
    try {
      answer = List<PlaceGuess>.unmodifiable(
        await geocoder.search(text, near: _center, locale: locale),
      );
    } catch (_) {
      failed = true;
    }
    if (_disposed || seq != _searchSeq) {
      mapsFinish(
        token,
        MapsTelemetry.resultStale,
        outcome: TelemetryOutcome.superseded,
      );
      return;
    }
    _searching = false;
    _searchFailed = failed;
    _results = answer;
    mapsFinish(
      token,
      failed
          ? MapsTelemetry.resultError
          : answer.isEmpty
          ? MapsTelemetry.resultEmpty
          : MapsTelemetry.resultFound,
      outcome: failed ? TelemetryOutcome.error : TelemetryOutcome.ok,
    );
    notifyListeners();
  }

  /// Drops the query and the results (and any search still on its way).
  void clear() {
    _searchSeq++;
    _query = '';
    _results = const [];
    _searching = false;
    _searchFailed = false;
    notifyListeners();
  }

  /// Moves the map to [place]. The pin takes its point at once and its label is the guess for
  /// it; the map's idle event at that point asks nothing more.
  Future<void> pick(PlaceGuess place) async {
    _searchSeq++;
    _reverseSeq++;
    _queued = null;
    // A fix still on its way must not move the map off the place that was just chosen.
    _locateSeq++;
    _results = const [];
    _searching = false;
    _chosen = true;
    _awaitingFix = false;
    _center = place.point;
    _guess = place;
    _guessFor = place.point;
    _guessing = false;
    _guessFailed = false;
    notifyListeners();
    await _moveTo(place.point);
  }

  Future<void> _moveTo(GeoPoint point) async {
    _chosen = true;
    _center = point;
    notifyListeners();
    try {
      await map.moveTo(point, zoom: focusZoom);
    } catch (_) {
      // A map that is not there costs the move, never the picker.
    }
  }

  /// The place to return, or null when the pin has no point or the map is still moving. The
  /// guess comes with it only when it was made for exactly this point.
  PickedPlace? confirm() {
    final point = _center;
    if (point == null || _moving) return null;
    final guess = _guessFor == point ? _guess : null;
    mapsPicked(guessed: guess != null);
    return PickedPlace(point, guess: guess);
  }

  /// Within about a metre: the map's idle point after a move to a picked place is not exactly it.
  static bool _near(GeoPoint a, GeoPoint b) =>
      (a.latitude - b.latitude).abs() < 1e-5 &&
      (a.longitude - b.longitude).abs() < 1e-5;
}
