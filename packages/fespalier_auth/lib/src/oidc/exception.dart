/// The provider answered something `fespalier_auth` cannot use (since 0.9.0): a redirect that does
/// not belong to the sign-in that opened it, an ID token for another issuer or client, a
/// discovery document that is not the provider's, a token endpoint that refused with an error
/// other than the ones that end a session.
///
/// [message] never carries a token, a code or a state. `toString` is `OidcException: <message>`.
final class OidcException implements Exception {
  /// An error with [message].
  const OidcException(this.message);

  /// What went wrong, in a sentence.
  final String message;

  @override
  String toString() => 'OidcException: $message';
}
