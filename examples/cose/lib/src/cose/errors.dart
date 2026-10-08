/// A message that failed a check on its received bytes: the coarse "401" of cratestack's
/// verifier. It carries no reason, so a caller cannot be turned into an oracle for which check
/// failed; the vectors only say that these must be refused.
final class CoseRejected implements Exception {
  /// A refusal.
  const CoseRejected();

  /// What cratestack's server answers every such request with.
  static const String unauthenticated = 'request could not be authenticated';

  @override
  String toString() => 'CoseRejected($unauthenticated)';
}

/// Local misuse, found before any received byte is read (cratestack answers these with a 500):
/// an empty audience, a `cti` of a length the header cannot carry, two bindings that differ in
/// more than the contract digest, a signer that returned a signature of the wrong length.
final class CoseMisuse implements Exception {
  /// A misuse, described for the developer.
  const CoseMisuse(this.message);

  /// What was wrong.
  final String message;

  @override
  String toString() => 'CoseMisuse($message)';
}
