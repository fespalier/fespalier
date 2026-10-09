/// The one rule for what counts as a write (since 0.15.0), shared by `WriteGuardClient` here and
/// `WriteGuard` in `fespalier_dio`, so the two clients never disagree.
///
/// A write is any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, unless it carries an
/// `Idempotency-Key` header (it is safe to repeat, so it is not one). A client with a way of
/// declaring a write whatever its method (Dio's `extra`) passes it as `declared`.
abstract final class HttpWrites {
  /// The methods that never change anything on the server.
  static const Set<String> safeMethods = {'GET', 'HEAD', 'OPTIONS', 'TRACE'};

  /// The header that makes a write repeatable, compared without regard to case.
  static const String idempotencyKey = 'Idempotency-Key';

  /// Whether a request with [method] and headers named [headerNames] is a write.
  ///
  /// `false` when an `Idempotency-Key` is among [headerNames], whatever else is said; otherwise
  /// [declared] or a method that is not safe.
  static bool isWrite(
    String method,
    Iterable<String> headerNames, {
    bool declared = false,
  }) {
    final key = idempotencyKey.toLowerCase();
    if (headerNames.any((name) => name.toLowerCase() == key)) return false;
    return declared || !safeMethods.contains(method.toUpperCase());
  }
}
