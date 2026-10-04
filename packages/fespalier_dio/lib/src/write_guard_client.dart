import 'package:http/http.dart' as http;

/// What [WriteGuardClient] saw of each response, by identity: true when it answered a write.
final Expando<bool> _writeResponses = Expando<bool>('fespalier_dio responses');

/// The errors a write's send threw through a [WriteGuardClient], by identity.
final Expando<bool> _writeErrors = Expando<bool>('fespalier_dio errors');

/// Marks what a write's send answered or threw, so `RetryClient` can leave writes alone (since
/// 0.9.0): fespalier never retries a write, and `RetryClient` retries a 503 on every method.
///
/// Put it **inside** the `RetryClient`, and give the `RetryClient` the two predicates:
///
/// ```dart
/// final client = RetryClient(
///   WriteGuardClient(http.Client()),
///   when: WriteGuardClient.readsOnly(),
///   whenError: WriteGuardClient.readErrorsOnly((error, stackTrace) => error is SocketException),
/// );
/// ```
///
/// It forwards every request to [inner] unchanged, and the response or the error it returns is the
/// very object the inner client made. It starts no timer and retries nothing itself.
final class WriteGuardClient extends http.BaseClient {
  /// A client that sends through [inner] and remembers which sends were writes.
  WriteGuardClient(this.inner);

  /// The client every request goes to. [close] closes it.
  final http.Client inner;

  static const Set<String> _safeMethods = {'GET', 'HEAD', 'OPTIONS', 'TRACE'};

  /// Whether [request] is a write (the `WriteGuard` rule: any method but `GET`, `HEAD`, `OPTIONS`
  /// and `TRACE`; an `Idempotency-Key` header makes it repeatable, so not one).
  static bool isWrite(http.BaseRequest request) {
    if (_safeMethods.contains(request.method.toUpperCase())) return false;
    return !request.headers.keys.any(
      (k) => k.toLowerCase() == 'idempotency-key',
    );
  }

  /// [when], for reads only: for `RetryClient(when:)`. By default [retryOn503], `RetryClient`'s own
  /// rule.
  ///
  /// A response is a write's when it came through a [WriteGuardClient] from a write, or, for one
  /// that did not, when its `request` says so. A response that says nothing about its request is
  /// not retried: it is the safe answer to "might this be a write?".
  static bool Function(http.BaseResponse response) readsOnly([
    bool Function(http.BaseResponse response) when = retryOn503,
  ]) =>
      (response) => !_isWriteResponse(response) && when(response);

  /// [whenError], except for an error a write's send threw through a [WriteGuardClient]: for
  /// `RetryClient(whenError:)`.
  static bool Function(Object error, StackTrace stackTrace) readErrorsOnly(
    bool Function(Object error, StackTrace stackTrace) whenError,
  ) =>
      (error, stackTrace) =>
          _writeErrors[error] != true && whenError(error, stackTrace);

  /// `RetryClient`'s default: a 503.
  static bool retryOn503(http.BaseResponse response) =>
      response.statusCode == 503;

  static bool _isWriteResponse(http.BaseResponse response) {
    final known = _writeResponses[response];
    if (known != null) return known;
    final request = response.request;
    return request == null || isWrite(request);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
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
          // An Expando cannot hold a string or a number; clients throw exceptions, so this stays
          // unmarked only for a client that throws something else.
        }
      }
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}
