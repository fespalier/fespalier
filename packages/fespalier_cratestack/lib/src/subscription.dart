import 'dart:convert';

import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// One change a CrateStack subscription (`@@subscribe`) sent (since 0.25.0): `model` had a row
/// `operation`ed at `occurredAt`.
///
/// **A hint, never the data to show.** CrateStack 0.15.4 applies no read policy to a subscription:
/// neither the model's `@@allow("read", ...)` nor its row policy is checked for an event, so the
/// row in the message is the row as the server wrote it, whoever reads the stream. Sync, or read
/// the row through the policy-checked API, and render what that gives; an app's `AuthProvider` must
/// refuse an anonymous subscriber, since nothing else does. So the row is **not kept**: [data] is
/// null unless the decoder was asked for it (`keepData: true`), which also keeps it in the 64-event
/// log of a `ChangeFeed.live` (a row can be large).
///
/// It does not override `==` (two events are two events, and Riverpod drops an equal value), and
/// `toString` prints the model and the operation only, never [data], [eventId] or the time.
final class CrateStackModelEvent {
  /// An event, as `crateStackEvents` decodes it.
  const CrateStackModelEvent({
    required this.model,
    required this.operation,
    this.eventId,
    this.occurredAt,
    this.data,
    this.sequence,
  });

  /// Decodes the `data:` of an `event: message`: `{"id": n, "next": {"event_id", "model",
  /// "operation", "occurred_at", "data"}}`. Throws a [FormatException] for anything else. The
  /// row (`"data"`) is dropped unless [keepData] is true.
  factory CrateStackModelEvent.fromJson(Object? json, {bool keepData = false}) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('a subscription message is a JSON object');
    }
    final next = json['next'];
    if (next is! Map<String, Object?>) {
      throw const FormatException('a subscription message has a "next" object');
    }
    final model = next['model'];
    final operation = next['operation'];
    if (model is! String || operation is! String) {
      throw const FormatException(
        'a model event names its "model" and "operation"',
      );
    }
    final eventId = next['event_id'];
    final occurredAt = next['occurred_at'];
    final sequence = json['id'];
    return CrateStackModelEvent(
      model: model,
      operation: operation,
      eventId: eventId is String ? eventId : null,
      occurredAt: occurredAt is String ? DateTime.tryParse(occurredAt) : null,
      data: keepData ? next['data'] : null,
      sequence: sequence is int ? sequence : null,
    );
  }

  /// The model's name, as the schema spells it (`Note`).
  final String model;

  /// What happened, as CrateStack sends it: `Created`, `Updated` or `Deleted` in 0.15.4 (the
  /// operations a model's `@@emit` lists). Compare it as a string: a newer server may add one.
  final String operation;

  /// The event's own id (a UUID), the same for every subscriber: what tells a duplicate after a
  /// reopen. It cannot resume a stream: CrateStack sends no `id:` field and ignores
  /// `Last-Event-ID`.
  final String? eventId;

  /// When the server committed the change, or null when it sent none it could read.
  final DateTime? occurredAt;

  /// The row as the server wrote it, unchecked by any read policy: a hint of what changed, never
  /// something to render (see the class comment). Null unless `keepData` was passed: an event that
  /// holds its row costs its size for as long as the feed's log keeps it.
  final Object? data;

  /// The message's number on this connection (the JSON `id`), from 1. It starts again on every
  /// connection, so it orders the events of one connection and says nothing across two.
  final int? sequence;

  /// Whether this is a `Created` event.
  bool get isCreated => operation == 'Created';

  /// Whether this is an `Updated` event.
  bool get isUpdated => operation == 'Updated';

  /// Whether this is a `Deleted` event.
  bool get isDeleted => operation == 'Deleted';

  @override
  String toString() => 'CrateStackModelEvent($model $operation)';
}

/// The subscription [opId] of the CrateStack server at [base], as a live connection of model
/// events (since 0.25.0): `GET <base>/rpc/subscribe/<opId>` with `Accept: text/event-stream`, sent
/// through [transport] like every other call, so the app's session, signature and trace apply.
///
/// ```dart
/// final serverChanges = ChangeFeed<CrateStackModelEvent>.live(
///   (ref, _) {
///     // Who is signed in: signing in or out as someone else replaces the connection.
///     ref.watch(crateStackScope);
///     return crateStackEvents(ref.watch(apiTransport), apiBase, 'model.Note.subscribe');
///   },
///   rules: LiveRules(reconnectOn: [reconnectSignal]),
/// );
/// ```
///
/// It is fespalier_stream's `ServerEvents` with a decoder in front, read the way CrateStack 0.15.4
/// writes it:
///
/// - each `event: message` is one [CrateStackModelEvent]; a message that is not one is skipped
///   and counted (`EventCodec`: [onSkipped], the `fespalier.stream.decode` span), never an error;
/// - `event: error` is what the server sends when the subscriber lagged (`unavailable`,
///   `subscription lagged`), and it ends the response after it: the event is dropped, the
///   connection opens again, and since the server sends no `id:`, **every reopen is a gap**, which
///   a `ChangeFeed.live` turns into a move of every watched key (so a push sync runs);
/// - there is no heartbeat: a quiet model sends nothing, so `LiveRules.idle` would close a healthy
///   connection. Leave it unset. A connection that died without a word is **not** found by a
///   `reconnectOn` signal or the `streamTicker` (they act on a connection that is waiting, or
///   idle); what replaces it is a rebuild of the feed, for instance `connect` watching
///   `appShowSignal` (each show of the app opens a new connection, which is a gap and so a sync);
/// - a server that refuses (a 401 from the `AuthProvider`, the 406 of a missing `Accept`) ends
///   the connection with `ServerEventsRefused`, and nothing opens it again except a rebuild: a
///   `connect` that watches who is signed in (`crateStackScope`) opens it after sign-in, and a
///   new account never reads the old one's connection.
///
/// [headers] are sent with every request (an `Accept` among them is replaced). [name] is what
/// fespalier_stream's telemetry reports for the connection (`[a-z][a-z0-9_]*`; none by default:
/// the operation id names a model). The events are hints: see [CrateStackModelEvent]; [keepData]
/// keeps their rows (off by default). [onSkipped] hears each message that did not decode with a
/// [FormatException] or another error whose text may quote the message (its `source` is the raw
/// event data, the row included): log its type, never the error.
LiveConnection<CrateStackModelEvent> crateStackEvents(
  HttpTransport transport,
  Uri base,
  String opId, {
  Map<String, String> headers = const <String, String>{},
  String? name,
  int maxEventBytes = 1 << 20,
  Map<String, Object?> attributes = const <String, Object?>{},
  bool keepData = false,
  void Function(Object reason, StackTrace stackTrace)? onSkipped,
}) => ServerEvents(
  transport,
  crateStackSubscribeUrl(base, opId),
  headers: <String, String>{
    for (final MapEntry(:key, :value) in headers.entries)
      if (key.toLowerCase() != 'accept') key: value,
    'Accept': 'text/event-stream',
  },
  name: name,
  maxEventBytes: maxEventBytes,
  attributes: attributes,
).transform(crateStackEventCodec(keepData: keepData, onSkipped: onSkipped));

/// `<base>/rpc/subscribe/<opId>` (since 0.25.0): [base]'s path, then the three segments, whether
/// or not [base] ends with a slash. Its query and fragment are dropped.
Uri crateStackSubscribeUrl(Uri base, String opId) => Uri(
  scheme: base.scheme,
  userInfo: base.userInfo,
  host: base.host,
  port: base.hasPort ? base.port : null,
  pathSegments: <String>[
    ...base.pathSegments.where((segment) => segment.isNotEmpty),
    'rpc',
    'subscribe',
    opId,
  ],
);

/// The decoder `crateStackEvents` puts in front of a connection (since 0.25.0), for an app that
/// opens the event stream itself: `event: message` is a [CrateStackModelEvent], `event: error`
/// (the lag notice) and any other type are dropped without being counted, and a message that
/// does not decode is skipped and counted. [keepData] keeps each event's row (see
/// [CrateStackModelEvent.data]). [onSkipped] is told why: a [FormatException] from the JSON parser
/// has the raw message as its `source` and quotes it in its text, row included, so log the type
/// and never the error or its `source`.
EventCodec<ServerEvent, CrateStackModelEvent> crateStackEventCodec({
  bool keepData = false,
  void Function(Object reason, StackTrace stackTrace)? onSkipped,
}) => EventCodec.batch<ServerEvent, ServerEvent, CrateStackModelEvent>(
  (event) => event.type == 'message' ? <ServerEvent>[event] : const [],
  (event) =>
      CrateStackModelEvent.fromJson(jsonDecode(event.data), keepData: keepData),
  onSkipped: onSkipped,
);
