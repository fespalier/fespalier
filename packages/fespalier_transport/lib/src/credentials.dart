import 'request.dart';
import 'response.dart';

/// The `TransportRequest.attributes` key a session sets to `true` on a send that follows a
/// verdict (a nonce challenge, a renewal) (since 0.21.0): `fespalier.auth.replay`. A write guard
/// lets that one send through. Never sent to a server.
const String transportReplayKey = 'fespalier.auth.replay';

/// The credentials one send of a request carried (since 0.15.0 in `fespalier_http`; here since
/// 0.21.0).
///
/// An [HttpCredentials] makes one per send; pass it back as `previous` when the same request is
/// sent again, so the retries are counted.
abstract interface class HttpAuthorization {
  /// The headers to attach to this send (`Authorization`, a signature, an attestation); empty
  /// when nothing was attached.
  Map<String, String> get headers;

  /// Whether this send is the one that follows a challenge or a renewal, so a request sent again.
  bool get isReplay;
}

/// What a transfer needs from a session (since 0.15.0 in `fespalier_http`; here since 0.21.0):
/// the headers for a request, and the answer to "send it once more?". `fespalier_auth`'s
/// `Authorizer` implements it.
///
/// A client of your own, or a transfer that is not a transport (a download, a plugin), asks
/// [authorize] before each send and [retry] after each response, and sends at most three times.
abstract interface class HttpCredentials {
  /// Whether [uri] is one this session's credentials may be sent to. Nothing else gets any.
  bool covers(Uri uri);

  /// The credentials for [request], with its headers and the exact bytes of its body (null
  /// when they are not known up front) for a scheme that signs them; empty headers when its URL
  /// is not covered or nobody is signed in. Pass the [previous] attempt of the same request when
  /// sending it again.
  ///
  /// Throws an `ArgumentError` when [previous] is not an attempt this object made.
  Future<HttpAuthorization> authorize(
    TransportRequest request, {
    HttpAuthorization? previous,
  });

  /// After [response] to [attempt]: whether to send the request once more, with
  /// `authorize(..., previous: attempt)`.
  ///
  /// The caller buffers the body of a 401 or a 403 (`TransportResponse.buffered`) before asking,
  /// so the credentials can read why the server refused; a response that is not buffered has no
  /// body to read here.
  Future<bool> retry(HttpAuthorization attempt, TransportResponse response);
}

/// The request with an [attempt]'s headers on top of its own, marked as a replay when the
/// attempt is one (since 0.21.0): what a client sends after [HttpCredentials.authorize].
extension AuthorizedTransportRequest on TransportRequest {
  /// This request carrying [attempt]'s headers.
  TransportRequest authorized(HttpAuthorization attempt) => copyWith(
    headers: <String, String>{...headers, ...attempt.headers},
    attributes: attempt.isReplay
        ? <String, Object?>{...attributes, transportReplayKey: true}
        : attributes,
  );
}
