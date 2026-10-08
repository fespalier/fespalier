import 'package:fespalier/fespalier.dart'
    show
        FespalierTelemetry,
        TelemetryEnd,
        TelemetryOp,
        TelemetryOutcome,
        TelemetryStart;

/// The names this package reports to a `FespalierTelemetry` sink (since 0.13.0), as
/// `TelemetryOp.custom` operations. They are this package's own contract, pinned by
/// `test/telemetry_test.dart`: add one, never rename one.
///
/// Every value is a constant from this class: **never a coordinate, a label, a query, an address
/// or an error's text** (a geocoder's exception message can carry the query). The attributes say
/// what kind of thing happened and how it ended, nothing about where.
abstract final class MapsTelemetry {
  /// A geocoder call: [direction] says which, [result] how it ended.
  static const String geocode = 'fespalier.maps.geocode';

  /// A position request: [result] says what the source answered.
  static const String locate = 'fespalier.maps.locate';

  /// The person confirmed a place: [guessed] says whether a guess came with it.
  static const String pick = 'fespalier.maps.pick';

  /// An offline pack download, from its start to how it ended (since 0.13.0): [kind] says what
  /// kind of pack, [result] how it ended. Never the pack's key, bounds, style or name.
  static const String download = 'fespalier.maps.download';

  /// Attribute of [download]: the kind of pack, [kindRegion] or [kindFile].
  static const String kind = 'fespalier.maps.kind';

  /// A MapLibre region pack.
  static const String kindRegion = 'region';

  /// A file pack (since 0.13.0): one file fetched over HTTP, resumable by byte offset.
  static const String kindFile = 'file';

  /// Attribute of [geocode]: [directionSearch] or [directionReverse].
  static const String direction = 'fespalier.maps.direction';

  /// A forward search (a typed query).
  static const String directionSearch = 'search';

  /// A reverse geocode (a point to a name).
  static const String directionReverse = 'reverse';

  /// Attribute of [geocode] and [locate], on the end: one of the `result*` values.
  static const String result = 'fespalier.maps.result';

  /// [geocode]: at least one place or a name came back.
  static const String resultFound = 'found';

  /// [geocode]: the geocoder answered, with nothing.
  static const String resultEmpty = 'empty';

  /// [geocode], [locate]: it threw, or no position could be had.
  static const String resultError = 'error';

  /// [geocode], [locate]: the answer arrived after a newer request and was dropped.
  static const String resultStale = 'stale';

  /// [locate]: a position was found.
  static const String resultFixed = 'fixed';

  /// [locate]: the location service is off.
  static const String resultOff = 'off';

  /// [locate]: the permission was refused.
  static const String resultDenied = 'denied';

  /// [download]: every resource arrived and the pack is complete.
  static const String resultComplete = 'complete';

  /// [download]: it failed (the pack's status says why, as a value).
  static const String resultFailed = 'failed';

  /// [download]: the pack was removed, or the owner of the download went away, before the end.
  static const String resultCancelled = 'cancelled';

  /// Attribute of [pick]: whether the confirmed place carries a guess.
  static const String guessed = 'fespalier.maps.guessed';
}

/// Starts a custom operation, or returns null when no sink is installed (the whole cost is one
/// null check). Never throws.
Object? mapsBegin(String name, [Map<String, Object>? attributes]) {
  if (FespalierTelemetry.current == null) return null;
  try {
    return FespalierTelemetry.begin(
      TelemetryStart(TelemetryOp.custom, name: name, attributes: attributes),
    );
  } catch (_) {
    // A failing sink costs the span, never the picker.
    return null;
  }
}

/// Ends what [mapsBegin] started. Never throws, and never carries an error: its text could hold
/// the query.
void mapsFinish(
  Object? token,
  String result, {
  String outcome = TelemetryOutcome.ok,
}) {
  if (token == null) return;
  try {
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(
        outcome,
        isAsync: true,
        attributes: {MapsTelemetry.result: result},
      ),
    );
  } catch (_) {
    // As above.
  }
}

/// A [MapsTelemetry.pick] operation, started and ended in the same call stack.
void mapsPicked({required bool guessed}) {
  final token = mapsBegin(MapsTelemetry.pick, {MapsTelemetry.guessed: guessed});
  if (token == null) return;
  try {
    FespalierTelemetry.finish(token, const TelemetryEnd(TelemetryOutcome.ok));
  } catch (_) {
    // As above.
  }
}
