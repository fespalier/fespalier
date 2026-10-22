import 'request.dart';
import 'response.dart';

/// Sends HTTP requests (since 0.21.0): the interface fespalier's networking packages build on,
/// implemented by `package:fespalier_http` (`package:http`), `package:fespalier_dio` (Dio) and
/// by an app's own client.
///
/// A decorator is a transport over a transport, and they compose:
/// `SessionTransport(WriteGuardTransport(HttpClientTransport(client)))`.
abstract interface class HttpTransport {
  /// Sends one request and answers once the headers are in; the body streams. Every status is an
  /// answer, not an error. Throws a `TransportFailure` when no response came back, and any other
  /// error a decorator throws for its own reasons (`AuthRejected` from a session).
  Future<TransportResponse> send(TransportRequest request);
}
