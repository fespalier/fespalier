/// Why a connection is waiting (since 0.25.0).
enum LiveDrop {
  /// The server ended the body in an orderly way and the connection did not open again at once:
  /// it sent no event on it, it asked for a delay with `retry:`, or it ended quick bodies one
  /// after the other.
  ended,

  /// No answer came back (a `TransportFailure`, or credentials that could not be reached), or the
  /// body broke while it was being read.
  failed,

  /// Nothing came from the server for longer than the feed's idle limit, so it was closed.
  idle,

  /// The server answered 408, 429 or a 5xx: try later.
  unavailable,
}

/// Why a connection ended for good (since 0.25.0): its `events` stream is done.
enum LiveEnd {
  /// The server answered 204 No Content: there is nothing to stream, and asking again is pointless
  /// (the WHATWG rule).
  done,

  /// The server refused (a 4xx other than 408 and 429, or a decorator's refusal such as a session
  /// that ended): `events` ended with a refusal, which a page shows as its error.
  refused,

  /// Something that is not an event stream answered (a 200 of another content type, a redirect
  /// that was not followed): `events` ended with `ServerEventsRejected`.
  rejected,

  /// A failure ended it: the simple form (`HttpTransport.serverEvents`) has no signal to
  /// reconnect on, so a drop ends its stream with the failure, and so does an error the package
  /// does not know as passing.
  failed,

  /// The app closed it, or its listener went away.
  closed,
}

/// Where a live connection is (since 0.25.0). Sealed: switch on it.
///
/// None of them is an error: a connection that dropped is [LiveWaiting] and its `events` stream
/// stays open (only [LiveDone] ends it). Every status has value equality and a `toString` with no
/// URL and nothing the server said.
sealed class LiveStatus {
  const LiveStatus();
}

/// A request is on its way, or about to be (since 0.25.0).
final class LiveConnecting extends LiveStatus {
  /// The [attempt]th try since the last connection that delivered an event (1 for the first).
  const LiveConnecting(this.attempt);

  /// 1 for the first try, then 2, 3... while tries end without an event.
  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is LiveConnecting && other.attempt == attempt;

  @override
  int get hashCode => Object.hash(LiveConnecting, attempt);

  @override
  String toString() => 'LiveConnecting($attempt)';
}

/// The server answered with an event stream, and it is being read (since 0.25.0).
final class LiveOpen extends LiveStatus {
  /// An open connection; [resumed] when it was asked for with a `Last-Event-ID`.
  const LiveOpen({this.resumed = false});

  /// Whether the request carried `Last-Event-ID`: the server may send what was missed.
  final bool resumed;

  @override
  bool operator ==(Object other) =>
      other is LiveOpen && other.resumed == resumed;

  @override
  int get hashCode => Object.hash(LiveOpen, resumed);

  @override
  String toString() => 'LiveOpen(resumed: $resumed)';
}

/// The listener paused the events (a hidden page, or Riverpod rebuilding what watches the feed)
/// (since 0.25.0): nothing is read.
///
/// A pause only stops reading; the connection is closed by `closeIfPaused` on the app's tick, and
/// a resume after that opens it again, with `Last-Event-ID`.
final class LivePaused extends LiveStatus {
  /// A paused connection; [connected] while its connection is still held.
  const LivePaused({required this.connected});

  /// Whether the connection is still held (false once the tick closed it, or when it was waiting).
  final bool connected;

  @override
  bool operator ==(Object other) =>
      other is LivePaused && other.connected == connected;

  @override
  int get hashCode => Object.hash(LivePaused, connected);

  @override
  String toString() => 'LivePaused(connected: $connected)';
}

/// The connection dropped and waits to be opened again (since 0.25.0): by `reconnect()` (a
/// `LiveFeed` calls it on its `reconnectOn` signals at once, and on the app's tick once
/// [retryHint] has passed since [since]).
final class LiveWaiting extends LiveStatus {
  /// A connection waiting since [since], after [drop].
  const LiveWaiting(
    this.drop, {
    required this.since,
    this.failures = 0,
    this.retryHint,
  });

  /// Why it dropped.
  final LiveDrop drop;

  /// When it dropped (`package:clock`'s time).
  final DateTime since;

  /// How many tries in a row ended without delivering an event, this one included, and 0 when
  /// this connection delivered events before it dropped: what an app's own backoff reads.
  final int failures;

  /// How long the server asked to wait: its `retry:` field, or a `Retry-After` in seconds on a
  /// 408, 429 or 5xx. Null when it said nothing.
  final Duration? retryHint;

  @override
  bool operator ==(Object other) =>
      other is LiveWaiting &&
      other.drop == drop &&
      other.since == since &&
      other.failures == failures &&
      other.retryHint == retryHint;

  @override
  int get hashCode =>
      Object.hash(LiveWaiting, drop, since, failures, retryHint);

  @override
  String toString() =>
      'LiveWaiting(${drop.name}, failures: $failures'
      '${retryHint == null ? '' : ', retryHint: ${retryHint!.inMilliseconds} ms'})';
}

/// The connection ended for good and its `events` stream is done (since 0.25.0).
final class LiveDone extends LiveStatus {
  /// A connection that ended with [end].
  const LiveDone(this.end);

  /// How it ended.
  final LiveEnd end;

  @override
  bool operator ==(Object other) => other is LiveDone && other.end == end;

  @override
  int get hashCode => Object.hash(LiveDone, end);

  @override
  String toString() => 'LiveDone(${end.name})';
}
