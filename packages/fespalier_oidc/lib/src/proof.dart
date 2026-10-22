/// Proof of possession for requests: DPoP (RFC 9449) (since 0.9.0 in `fespalier_auth`; here since
/// 0.21.0). `package:fespalier_keypair_dpop` implements it (`DpopProof`).
///
/// The backend owns it: it signs the token-endpoint calls with it, and the `BearerAuthenticator`
/// signs each API call.
abstract interface class ProofOfPossession {
  /// The key's RFC 7638 thumbprint (the key is made on first use); null when proofs are off on
  /// this device.
  Future<String?> thumbprint();

  /// The headers proving possession for [method] [uri] (`{'DPoP': '<jwt>'}`), with `ath` when
  /// [accessToken] is given; empty when proofs are off.
  Future<Map<String, String>> headers({
    required String method,
    required Uri uri,
    String? accessToken,
  });

  /// Called with every response to a request [headers] was used for: records a `DPoP-Nonce`, and
  /// returns true when the request should be sent once more with new headers (a nonce challenge,
  /// a clock correction), never when [retried] is true. [body] is given for authorization-server
  /// responses.
  bool onResponse({
    required Uri uri,
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  });

  /// The session ended: forget nonces and the clock correction. `DpopProof` also deletes the
  /// key.
  Future<void> reset();
}
