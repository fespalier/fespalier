import 'dart:async';

import 'live_status.dart';

/// A connection that delivers a server's events for as long as it is listened to, and reconnects
/// when it is told to (since 0.25.0). `ServerEvents` is the server-sent events one.
///
/// It never waits on its own: no timer, no backoff. A drop makes it [LiveWaiting], and the next
/// [reconnect] (the app's signal, or its tick) opens it again. A listener's pause stops reading;
/// [closeIfPaused] (the app's tick) closes a connection that stayed paused; a resume opens it
/// again. A `LiveFeed` calls all of these for you.
abstract interface class LiveConnection<T> {
  /// The events, single-subscription. Listening opens the connection, a pause stops reading (at
  /// most the chunk it was waiting for is still read, and held), and cancelling closes it for
  /// good. It ends when the connection is [LiveDone]: with an error for a refusal or a failure,
  /// without one for a 204 or a [close]. A drop is not an error: the stream stays open while the
  /// connection waits.
  Stream<T> get events;

  /// Where the connection is now.
  LiveStatus get status;

  /// [status] first, then each change, for any number of listeners. It ends after [LiveDone].
  Stream<LiveStatus> get statusChanges;

  /// When the last bytes came from the server (`package:clock`'s time), events and comments
  /// alike; null before the first.
  DateTime? get lastSeen;

  /// The ID another connection would resume from (`Last-Event-ID`): that of the last event the
  /// listener was handed, so events read and held while it was paused are asked for again. Null
  /// when there is none, or when the connection cannot resume.
  String? get lastEventId;

  /// Opens the connection now when it is [LiveWaiting], and answers whether it did. A paused one
  /// does not open, but remembers the call and opens on resume.
  bool reconnect();

  /// Closes an open connection whose server said nothing (no event, no comment) for [limit] or
  /// longer, and answers whether it did: it is [LiveWaiting] with [LiveDrop.idle] then. Only
  /// meaningful for a server that sends comments while it has nothing to say.
  bool closeIfIdle(Duration limit);

  /// Closes a connection that is still paused since the previous call (a pause has to outlast one
  /// whole tick, so Riverpod's brief pauses while it rebuilds never close it), and answers whether
  /// it did. A resume opens it again, with `Last-Event-ID`.
  bool closeIfPaused();

  /// Closes the connection for good: [LiveDone] with [LiveEnd.closed], and [events] ends.
  Future<void> close();
}

/// [LiveConnection.events] converted (since 0.25.0): `ServerEvents(...).map(Order.fromEvent)`.
extension LiveConnectionConvert<T> on LiveConnection<T> {
  /// This connection, with each event converted by [convert]. An error [convert] throws reaches
  /// the listener as an error of `events`, which goes on.
  LiveConnection<U> map<U>(U Function(T event) convert) =>
      _Converted<T, U>(this, (events) => events.map(convert));

  /// This connection, with its events run through [transformer] (an `EventCodec`, a filter).
  LiveConnection<U> transform<U>(StreamTransformer<T, U> transformer) =>
      _Converted<T, U>(this, (events) => events.transform(transformer));
}

final class _Converted<T, U> implements LiveConnection<U> {
  _Converted(this._source, this._convert);

  final LiveConnection<T> _source;
  final Stream<U> Function(Stream<T> events) _convert;

  @override
  Stream<U> get events => _convert(_source.events);

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
  String toString() => 'LiveConnection';
}
