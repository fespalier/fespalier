import 'request.dart';
import 'response.dart';
import 'transport.dart';
import 'writes.dart';

/// What [WriteGuardTransport] saw of each response, by identity: true when it answered a write.
final Expando<bool> _writeResponses = Expando<bool>(
  'fespalier_transport responses',
);

/// The errors a write's send threw through a [WriteGuardTransport], by identity.
final Expando<bool> _writeErrors = Expando<bool>('fespalier_transport errors');

/// Marks what a write's send answered or threw, so a retrier above it can leave writes alone
/// (since 0.21.0; it was `WriteGuardClient` in `fespalier_http`): fespalier never retries a
/// write, and a retrier retries a 503 on every method.
///
/// ```dart
/// final transport = WriteGuardTransport(HttpClientTransport(client));
/// // a retrier over it asks: !WriteGuardTransport.isWriteResponse(response)
/// ```
///
/// It forwards every request unchanged, and the response or the error it returns is the very
/// object the inner transport made. It starts no timer and retries nothing itself.
final class WriteGuardTransport implements HttpTransport {
  /// A transport that sends through [inner] and remembers which sends were writes.
  const WriteGuardTransport(this.inner);

  /// The transport every request goes to.
  final HttpTransport inner;

  /// Whether [request] is a write (the [HttpWrites] rule: any method but `GET`, `HEAD`,
  /// `OPTIONS` and `TRACE`; an `Idempotency-Key` header makes it repeatable, so not one).
  static bool isWrite(TransportRequest request) =>
      HttpWrites.isWriteRequest(request);

  /// Whether [response] answered a write sent through a [WriteGuardTransport]. A response that
  /// did not come through one says nothing, and counts as a write: it is the safe answer to
  /// "might this be a write?".
  static bool isWriteResponse(TransportResponse response) =>
      _writeResponses[response] ?? true;

  /// Whether [error] was thrown by the send of a write through a [WriteGuardTransport].
  static bool isWriteError(Object error) => _writeErrors[error] ?? false;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final write = isWrite(request);
    try {
      final response = await inner.send(request);
      _writeResponses[response] = write;
      return response;
    } on Object catch (error) {
      if (write) {
        try {
          _writeErrors[error] = true;
        } on ArgumentError {
          // An Expando cannot hold a string or a number; transports throw exceptions, so this
          // stays unmarked only for a client that throws something else.
        }
      }
      rethrow;
    }
  }
}
