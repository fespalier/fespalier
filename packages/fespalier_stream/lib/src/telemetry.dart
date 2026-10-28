import 'dart:async';

import 'package:fespalier/fespalier.dart';

import 'wire/event_source.dart';

/// The telemetry names of fespalier_stream (since 0.25.0): constants only. They are this package's
/// contract (`fespalier.<package>.*`), not contract version 1's: adding is fine, renaming or
/// removing is a breaking release.
///
/// Two short root spans per connection, never one span that lives as long as the connection (an
/// exporter would hold it for hours, and a crash would lose it):
///
/// - [open] starts when a request is sent and ends at the answer: [result] (`open`, `done`,
///   `refused`, `rejected`, `unavailable`, `failed`, `cancelled`), [statusCode] when a status
///   came, [resumed] when it carried `Last-Event-ID`.
/// - [close] starts and ends when a connection that was open ends: [reason] (`ended`, `failed`,
///   `idle`, `paused`, `cancelled`) and the number of [events] it delivered.
///
/// Both carry [kind] (`sse`) and, when the connection was given one, [name]. Neither carries a URL,
/// a query, a header, an event's type, data or id, or an error's text.
abstract final class FespalierStreamConventions {
  /// The span of one request, from its send to its answer.
  static const String open = 'fespalier.stream.open';

  /// The instant span of the end of a connection that was open.
  static const String close = 'fespalier.stream.close';

  /// What kind of connection: [kindSse].
  static const String kind = 'fespalier.stream.kind';

  /// The kind of a server-sent events connection.
  static const String kindSse = 'sse';

  /// The connection's name, as the app gave it (`orders`), when it gave one.
  static const String name = 'fespalier.stream.name';

  /// The answer of an [open]: `open`, `done`, `refused`, `rejected`, `unavailable`, `failed` or
  /// `cancelled`.
  static const String result = 'fespalier.stream.result';

  /// Whether the request of an [open] carried `Last-Event-ID`.
  static const String resumed = 'fespalier.stream.resumed';

  /// The HTTP status of an [open], when one came back.
  static const String statusCode = 'fespalier.stream.status_code';

  /// Why a [close] happened: `ended`, `failed`, `idle`, `paused` or `cancelled`.
  static const String reason = 'fespalier.stream.reason';

  /// How many events a [close]d connection delivered.
  static const String events = 'fespalier.stream.events';
}

final RegExp _name = RegExp(r'^[a-z][a-z0-9_]*$');

/// Whether [name] may be reported: lower-case letters, digits and underscores (`orders_live`), the
/// shape of a constant name you choose and not of a URL. It checks the shape only, so give a
/// constant: a name built from an id (`order_42`) passes. Always true for null.
bool isTelemetryName(String? name) => name == null || _name.hasMatch(name);

Map<String, Object> _base(String? name) => <String, Object>{
  FespalierStreamConventions.kind: FespalierStreamConventions.kindSse,
  FespalierStreamConventions.name: ?name,
};

/// Starts the open span of a request (a root span: see [reportStreamClose]); null without a sink.
Object? reportStreamOpenStart({String? name, required bool resumed}) {
  if (FespalierTelemetry.current == null) return null;
  return Zone.root.run(
    () => FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.custom,
        name: FespalierStreamConventions.open,
        attributes: <String, Object>{
          ..._base(name),
          FespalierStreamConventions.resumed: resumed,
        },
      ),
    ),
  );
}

/// Ends the open span [token] with [result] and the [statusCode] that came, when one did.
void reportStreamOpenEnd(Object? token, String result, {int? statusCode}) {
  if (token == null || FespalierTelemetry.current == null) return;
  final outcome = switch (result) {
    OpenResult.open || OpenResult.done => TelemetryOutcome.ok,
    OpenResult.refused => TelemetryOutcome.rejected,
    OpenResult.cancelled => TelemetryOutcome.cancelled,
    _ => TelemetryOutcome.error,
  };
  Zone.root.run(
    () => FespalierTelemetry.finish(
      token,
      TelemetryEnd(
        outcome,
        isAsync: true,
        attributes: <String, Object>{
          FespalierStreamConventions.result: result,
          FespalierStreamConventions.statusCode: ?statusCode,
        },
      ),
    ),
  );
}

/// Reports the end of a connection that was open, as a span that starts and ends at once.
///
/// Both spans are **root spans**: they run in the root zone, because a connection is opened and
/// read in the zone of whoever first watched the feed (a page's, long gone), and a sink that reads
/// `Zone.current` would make them children of whatever that zone was doing. Synchronous: no
/// `Future`, no microtask, no timer; without a sink, one null check.
void reportStreamClose({
  String? name,
  required String reason,
  required int events,
}) {
  if (FespalierTelemetry.current == null) return;
  Zone.root.run(() {
    final token = FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.custom,
        name: FespalierStreamConventions.close,
        attributes: _base(name),
      ),
    );
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(
        reason == CloseReason.failed
            ? TelemetryOutcome.error
            : TelemetryOutcome.ok,
        attributes: <String, Object>{
          FespalierStreamConventions.reason: reason,
          FespalierStreamConventions.events: events,
        },
      ),
    );
  });
}
