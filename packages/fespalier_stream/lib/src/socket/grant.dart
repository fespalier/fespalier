/// What one connection attempt of a `SocketConnection` connects with (since 0.25.0): the URL, and
/// the protocols and headers to add, as a [SocketGrantor] made them.
///
/// It holds a credential (a ticket in [url]'s query, a header), so `toString` prints no field.
final class SocketGrant {
  /// A grant to connect to [url], offering [protocols], with [headers] on the handshake (native
  /// only: a browser cannot set them).
  const SocketGrant(
    this.url, {
    this.protocols = const <String>[],
    this.headers = const <String, String>{},
  });

  /// The URL to connect to, with whatever the grantor put in its query.
  final Uri url;

  /// The subprotocols to offer, after the connection's own.
  final List<String> protocols;

  /// The handshake's headers, over the connection's own.
  final Map<String, String> headers;

  @override
  String toString() => 'SocketGrant';
}

/// Fetches what one connection attempt to [url] connects with (since 0.25.0): asked once before
/// every connect, so a single-use ticket is fresh each time.
///
/// It runs in a zone whose `TransportZone` abort trigger completes when the connection gives the
/// attempt up, so a request it sends through a transport is aborted with it. A refusal it throws
/// (a `DataRefusal`, such as a session that ended) ends the connection; another `Exception` makes
/// it wait (`LiveWaiting` with `failed`, or `unavailable` for a `TransportStatusError` 408, 429 or
/// 5xx) for its next reconnect.
typedef SocketGrantor = Future<SocketGrant> Function(Uri url);
