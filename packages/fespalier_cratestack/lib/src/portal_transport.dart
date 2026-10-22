import 'package:fespalier_transport/fespalier_transport.dart'
    show HttpTransport, TransportPortal, TransportRequest, TransportResponse;

/// A transport that turns a web page where an answer was expected into a `TransportPortal`
/// (since 0.21.0; it replaces `CrateStackPortalInterceptor`).
///
/// A captive portal's or a gateway's HTML page can arrive with a `200`, which no transport treats
/// as a failure, and the generated client cannot decode it. This decorator reads the `content-type`
/// of every answer and, for `text/html`, drains the body and throws `TransportPortal` instead:
/// nobody that knows CrateStack answered. [TransportFailures.read] reads that as
/// `CrateStackOffline`, so a write keeps its key. Requests, and their `attributes` (the auth
/// replay mark, the memo), go through to [inner] unchanged. It starts no timer and listens to
/// nothing.
///
/// ```dart
/// final chain = PortalTransport(WriteGuardTransport(HttpClientTransport(client)));
/// dio.httpClientAdapter = TransportAdapter(chain);
/// ```
final class PortalTransport implements HttpTransport {
  /// A decorator over [inner].
  const PortalTransport(this.inner);

  /// What the request is sent through.
  final HttpTransport inner;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final response = await inner.send(request);
    final type = response.headers['content-type'];
    if (type != null && type.toLowerCase().contains('text/html')) {
      // Read it out so the connection is released; the page itself is dropped.
      await response.bytes();
      throw TransportPortal(null, request.uri);
    }
    return response;
  }
}
