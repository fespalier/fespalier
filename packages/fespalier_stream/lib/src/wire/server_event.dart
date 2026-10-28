/// What an event stream says, item by item (since 0.25.0): an event, a last event ID set by a
/// block with no data, the server's reconnection delay, or a comment. Sealed: switch on it.
///
/// `EventStreamDecoder` makes them from the bytes of a `text/event-stream` body.
sealed class EventStreamItem {
  const EventStreamItem();
}

/// One dispatched event of a `text/event-stream` body (since 0.25.0), as the WHATWG
/// HTML standard's "dispatch the event" makes it.
///
/// It does not override `==`, on purpose: two events with the same type, data and id are two
/// events, and Riverpod 3 does not notify a provider whose new value is `==` its old one, so an
/// "order 42 changed" said twice in a row would reach a watcher once. `toString` prints no field:
/// the data, the type and the id are the server's, and can name a user.
final class ServerEvent extends EventStreamItem {
  /// An event of [type] (`message` when the server named none) carrying [data], with the last
  /// event ID [id] the stream had set when it was dispatched.
  const ServerEvent(this.data, {this.type = 'message', this.id});

  /// The `event:` field, or `message`.
  final String type;

  /// The `data:` lines joined with a line feed, without the last one.
  final String data;

  /// The last event ID of the stream when this event was dispatched: the value of the latest
  /// `id:` field the server sent on this connection, on this event or an earlier one, or null when
  /// it sent none (or an empty one, which clears it). It is what a reconnection sends as
  /// `Last-Event-ID`.
  final String? id;

  @override
  String toString() => 'ServerEvent';
}

/// A block with an `id:` field and no `data:` line (since 0.25.0): it dispatches no event, but the
/// WHATWG standard sets the last event ID from the field as it reads it, so a reconnection sends
/// it as `Last-Event-ID` all the same (a server may send `id: 9` alone to move a client's position
/// past events it will not show). [id] is null when the field was empty, which clears the last
/// event ID. `toString` prints no field: the ID is the server's.
final class EventIdUpdate extends EventStreamItem {
  /// An update to [id].
  const EventIdUpdate(this.id);

  /// The new last event ID, or null when the block cleared it.
  final String? id;

  @override
  bool operator ==(Object other) => other is EventIdUpdate && other.id == id;

  @override
  int get hashCode => Object.hash(EventIdUpdate, id);

  @override
  String toString() => 'EventIdUpdate';
}

/// The server's `retry:` field (since 0.25.0): how long it asks a client to wait before it
/// reconnects, at most [maxRetry] (a larger value is clamped to it). fespalier_stream starts no timer: a `LiveFeed` waits for at least this long on the
/// app's tick before it reconnects, and an app that reconnects by itself reads it in
/// `LiveWaiting.retryHint`.
final class RetryHint extends EventStreamItem {
  /// A hint of [delay].
  const RetryHint(this.delay);

  /// The delay the server asked for.
  final Duration delay;

  /// The longest delay a hint carries, a day: the decoder clamps a larger `retry:` value to it
  /// (it would overflow a `Duration` in the end, and no client waits that long).
  static const Duration maxRetry = Duration(hours: 24);

  @override
  bool operator ==(Object other) => other is RetryHint && other.delay == delay;

  @override
  int get hashCode => delay.hashCode;

  @override
  String toString() => 'RetryHint(${delay.inMilliseconds} ms)';
}

/// A comment line (`: ...`) (since 0.25.0): what a server sends to keep a connection alive
/// through proxies, and what tells a client the connection still works. Its text is not kept.
final class Heartbeat extends EventStreamItem {
  /// A comment.
  const Heartbeat();

  @override
  bool operator ==(Object other) => other is Heartbeat;

  @override
  int get hashCode => (Heartbeat).hashCode;

  @override
  String toString() => 'Heartbeat';
}
