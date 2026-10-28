import 'package:fespalier/fespalier.dart' show DataRefusal;
import 'package:fespalier_transport/fespalier_transport.dart';

import 'errors.dart';
import 'telemetry.dart';
import 'wire/event_source.dart';
import 'wire/live_connection.dart';
import 'wire/live_status.dart';
import 'wire/server_event.dart';

/// A server-sent events connection over the app's [HttpTransport] (since 0.25.0): a
/// `LiveConnection<ServerEvent>`.
///
/// ```dart
/// final orders = ServerEvents(transport, Uri.parse('https://api.example.com/orders/live'),
///     name: 'orders');
/// ```
///
/// It is a `GET` through the transport with `Accept: text/event-stream`, `Cache-Control:
/// no-cache` and the [headers] given, so a session, a signature or a trace that decorates the
/// transport applies to it as to any request (a browser `EventSource` could carry none of them).
/// It opens when [events] is listened to and follows the WHATWG rules, with no timer:
///
/// - a 200 `text/event-stream` is open; its events are decoded by `EventStreamDecoder`;
/// - an orderly end after at least one event opens again at once, with `Last-Event-ID`, unless
///   the server asked for a delay with `retry:` or the connection ended in an orderly way less
///   than a second after it opened for the second time in a row; those, an end with no event, a
///   `TransportFailure`, a body that breaks, a 408, 429 or 5xx wait ([LiveWaiting]) for
///   [reconnect];
/// - a 204 ends [events] (`LiveDone(done)`); another 4xx, or a decorator's refusal, ends it with
///   [ServerEventsRefused] (or that refusal); a 200 of another type, or a status no event stream
///   has, with [ServerEventsRejected].
///
/// `lastEventId` resumes from an ID the app kept; afterwards the connection keeps the last one
/// itself. [name] (`[a-z][a-z0-9_]*`) is what telemetry reports; `maxEventBytes` bounds one event
/// (`EventStreamTooLarge`, a drop); `attributes` go to the transport's decorators with each
/// request. Every request carries an `abortTrigger` that the connection completes whenever it
/// gives the request up (a cancel, a close, a pause or idle close), so the client lets the
/// connection go whatever it does with a cancelled body.
final class ServerEvents implements LiveConnection<ServerEvent> {
  /// A connection to [url] through [transport].
  ServerEvents(
    HttpTransport transport,
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    String? lastEventId,
    this.name,
    int maxEventBytes = 1 << 20,
    Map<String, Object?> attributes = const <String, Object?>{},
  }) : assert(
         isTelemetryName(name),
         'ServerEvents name must match [a-z][a-z0-9_]*: telemetry reports it',
       ) {
    _source = EventSource(
      transport,
      url,
      hooks: _Hooks(name),
      headers: headers,
      lastEventId: lastEventId,
      maxEventBytes: maxEventBytes,
      attributes: attributes,
    );
  }

  ServerEvents._simple(
    HttpTransport transport,
    Uri url, {
    required Map<String, String> headers,
    required this.name,
  }) : assert(
         isTelemetryName(name),
         'serverEvents name must match [a-z][a-z0-9_]*: telemetry reports it',
       ) {
    _source = EventSource(
      transport,
      url,
      hooks: _Hooks(name),
      headers: headers,
      endsOnDrop: true,
    );
  }

  late final EventSource _source;

  /// The name telemetry reports (`fespalier.stream.name`), or null.
  final String? name;

  /// The event stream's URL.
  Uri get url => _source.url;

  @override
  Stream<ServerEvent> get events => _source.events;

  @override
  LiveStatus get status => _source.status;

  @override
  Stream<LiveStatus> get statusChanges => _source.statusChanges;

  @override
  DateTime? get lastSeen => _source.lastSeen;

  @override
  String? get lastEventId => _source.lastEventId;

  @override
  bool reconnect() => _source.reconnect();

  @override
  bool closeIfIdle(Duration limit) => _source.closeIfIdle(limit);

  @override
  bool closeIfPaused() => _source.closeIfPaused();

  @override
  Future<void> close() => _source.close();

  @override
  String toString() => 'ServerEvents($status)';
}

final class _Hooks implements EventSourceHooks {
  _Hooks(this.name);

  final String? name;

  @override
  Object refusedError(int statusCode) => ServerEventsRefused(statusCode);

  @override
  Object rejectedError({int? statusCode, String? contentType}) =>
      ServerEventsRejected(statusCode: statusCode, contentType: contentType);

  @override
  Object unavailableError(int statusCode, Duration? retryAfter) =>
      ServerEventsUnavailable(statusCode, retryAfter: retryAfter);

  @override
  bool isRefusal(Object error) => error is DataRefusal;

  @override
  Object? reportOpenStart({required bool resumed}) =>
      reportStreamOpenStart(name: name, resumed: resumed);

  @override
  void reportOpenEnd(Object? token, String result, {int? statusCode}) =>
      reportStreamOpenEnd(token, result, statusCode: statusCode);

  @override
  void reportClose(String reason, int events) =>
      reportStreamClose(name: name, reason: reason, events: events);
}

/// The simple form (since 0.25.0): an event stream as a `Stream`, for a `data.dart`.
extension ServerEventsOnTransport on HttpTransport {
  /// The events of [url], as a plain stream, for a `data.dart` that returns a `Stream`:
  ///
  /// ```dart
  /// Stream<ServerEvent> data(Ref ref) => ref.watch(apiTransport).serverEvents(ordersLive);
  /// ```
  ///
  /// It has no signal to reconnect on, so what a `LiveFeed` would wait through ends it instead:
  /// a failure before an event, or a drop later, ends the stream with the error (the
  /// `TransportFailure`, a `TransportBroken` for a body that broke, a [ServerEventsUnavailable]
  /// for a 408, 429 or 5xx), which `error.dart` shows and the app's retry policy may act on; a
  /// refusal ends it with [ServerEventsRefused]. An orderly end after events still opens again at
  /// once with `Last-Event-ID` (unless the server sent `retry:` or ended quick bodies in a row,
  /// which it has no timer to wait for: the stream ends), and an end with none, or a 204, ends
  /// the stream. A pause stops
  /// reading but holds the connection (nothing closes it on a tick): a page that stays hidden
  /// wants a `LiveFeed`. Cancelling the subscription aborts the request.
  Stream<ServerEvent> serverEvents(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    String? name,
  }) => ServerEvents._simple(this, url, headers: headers, name: name).events;
}
