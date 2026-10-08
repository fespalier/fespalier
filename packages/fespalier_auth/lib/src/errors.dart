import 'package:fespalier/fespalier.dart' show DataRefusal;
import 'package:http/http.dart' as http;

/// The server refused the session: an OAuth error such as `invalid_grant` (since 0.9.0). The
/// session is over, and the user has to sign in again. A [DataRefusal] (since 0.13.1).
final class AuthRejected implements Exception, DataRefusal {
  /// The refusal: the OAuth [error] code, and the server's [description] when it gave one.
  const AuthRejected([this.error = 'invalid_grant', this.description]);

  /// The OAuth error code (`invalid_grant`, `invalid_client`, ...).
  final String error;

  /// The server's `error_description`, when there is one.
  final String? description;

  @override
  String toString() =>
      'AuthRejected: the server refused the session ($error'
      '${description == null ? '' : ': $description'})';
}

/// The session could not be refreshed for now (offline, a 5xx): the session stays, and the next
/// request tries again (since 0.9.0).
///
/// A [http.ClientException], so code that catches `package:http`'s network errors catches this
/// one too. Its text never names the server.
final class AuthUnavailable extends http.ClientException {
  /// Wraps what stopped the refresh: [cause].
  AuthUnavailable(this.cause, [Uri? uri])
    : super(
        "fespalier_auth: couldn't refresh the session: ${_describe(cause)}",
        uri,
      );

  /// What stopped it: a socket error, a timeout, a 5xx.
  final Object cause;

  static String _describe(Object cause) => cause is http.ClientException
      ? 'ClientException: ${cause.message}'
      : '$cause';
}

/// The user closed or cancelled the sign-in (since 0.9.0). Not an error to report: a form shows
/// nothing.
final class AuthCancelled implements Exception {
  /// A cancelled sign-in.
  const AuthCancelled();

  @override
  String toString() => 'AuthCancelled: the sign-in was cancelled';
}

/// `tokens()` was asked while nobody is signed in, or the session ended while a request waited
/// for it (since 0.9.0).
final class NotSignedIn extends StateError {
  /// The error for a request made with no session.
  NotSignedIn() : super('fespalier_auth: not signed in');
}
