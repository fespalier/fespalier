/// The credentials one send of a request carried (since 0.15.0).
///
/// An [HttpCredentials] makes one per send; pass it back as `previous` when the same request is
/// sent again, so the retries are counted.
abstract interface class HttpAuthorization {
  /// The HTTP method this send is for.
  String get method;

  /// The URL this send is for.
  Uri get uri;

  /// The headers to attach to this send (`Authorization`, and whatever a proof adds); empty when
  /// nothing was attached.
  Map<String, String> get headers;

  /// Whether this send is the one that follows a challenge or a refresh, so a request sent again.
  bool get isReplay;
}

/// What a transfer needs from a session (since 0.15.0): the headers for a request, and the answer
/// to "send it once more?". `fespalier_auth`'s `Authorizer` implements it.
///
/// A client of your own, or a transfer that is not an `http.Client` (a download, a plugin), asks
/// [authorize] before each send and [retry] after each response, and sends at most three times.
abstract interface class HttpCredentials {
  /// Whether [uri] is one this session's credentials may be sent to. Nothing else gets any.
  bool covers(Uri uri);

  /// The credentials for [method] [uri]; empty headers when [uri] is not covered or nobody is
  /// signed in. Pass the [previous] attempt of the same request when sending it again.
  ///
  /// Throws an `ArgumentError` when [previous] is not an attempt this object made.
  Future<HttpAuthorization> authorize(
    String method,
    Uri uri, {
    HttpAuthorization? previous,
  });

  /// After the response to [attempt] ([statusCode] and its [headers], with lower-case names):
  /// whether to send the request once more, with `authorize(..., previous: attempt)`.
  Future<bool> retry(
    HttpAuthorization attempt, {
    required int statusCode,
    required Map<String, String> headers,
  });
}
