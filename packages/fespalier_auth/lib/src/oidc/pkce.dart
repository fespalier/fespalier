import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../jwt.dart';

/// A PKCE pair (RFC 7636, method S256): the [verifier] stays in the app until the code is
/// exchanged, and only its hash, the [challenge], goes through the browser.
final class Pkce {
  Pkce._(this.verifier, this.challenge);

  /// A new pair from [random]: 32 random bytes, base64url without padding (43 characters), and
  /// `base64url(sha256(ascii(verifier)))`.
  factory Pkce.generate(Random random) {
    final verifier = randomToken(random, 32);
    return Pkce._(verifier, challengeFor(verifier));
  }

  /// The secret that proves the code was asked for by this app.
  final String verifier;

  /// What goes in the authorization URL as `code_challenge`.
  final String challenge;

  /// `base64url(sha256(ascii(verifier)))`, no padding.
  static String challengeFor(String verifier) =>
      base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);
}

/// [bytes] random bytes from [random], base64url without padding: a `state`, a `nonce`, a verifier.
String randomToken(Random random, int bytes) =>
    base64UrlNoPad(List<int>.generate(bytes, (_) => random.nextInt(256)));
