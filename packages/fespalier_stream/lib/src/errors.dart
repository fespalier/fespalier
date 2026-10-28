import 'package:fespalier/fespalier.dart' show DataRefusal;

/// The server refused the event stream (since 0.25.0): it answered a 4xx other than 408 and 429
/// (after a session's renewal and resend, for a 401). The connection ended for good.
///
/// It is a [DataRefusal], so a page that keeps its value on an error shows `error.dart` instead:
/// the person may no longer see what the stream was about. `toString` shows the status only.
final class ServerEventsRefused implements Exception, DataRefusal {
  /// A refusal with [statusCode].
  const ServerEventsRefused(this.statusCode);

  /// The HTTP status code.
  final int statusCode;

  @override
  String toString() => 'ServerEventsRefused: HTTP $statusCode';
}

/// Something other than an event stream answered (since 0.25.0): a 200 whose content type is not
/// `text/event-stream` (a login page, a proxy's error page), or a status no event stream has. The
/// connection ended for good: asking again would get the same answer.
final class ServerEventsRejected implements Exception {
  /// A rejected answer, with its [statusCode] and [contentType] when known.
  const ServerEventsRejected({this.statusCode, this.contentType});

  /// The HTTP status code.
  final int? statusCode;

  /// The `content-type` that came back, or null when there was none.
  final String? contentType;

  @override
  String toString() =>
      'ServerEventsRejected: HTTP $statusCode is not an event stream';
}

/// The server said to try later (since 0.25.0): a 408, a 429 or a 5xx. A `LiveFeed` waits for its
/// next signal instead; the simple form (`HttpTransport.serverEvents`), which has none, ends with
/// it.
final class ServerEventsUnavailable implements Exception {
  /// An answer with [statusCode] and the `Retry-After` it carried, in seconds, when it did.
  const ServerEventsUnavailable(this.statusCode, {this.retryAfter});

  /// The HTTP status code.
  final int statusCode;

  /// The server's `Retry-After`, when it sent one in seconds.
  final Duration? retryAfter;

  @override
  String toString() => 'ServerEventsUnavailable: HTTP $statusCode';
}
