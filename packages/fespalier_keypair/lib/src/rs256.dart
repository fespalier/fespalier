import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'jose.dart';

// The DER prefix of a SHA-256 DigestInfo, as RSASSA-PKCS1-v1_5 (RFC 8017 9.2) wraps the digest.
const String _sha256DigestInfo = '0609608648016503040201';

/// The shortest RSA modulus [verifyRs256] accepts, in bits: 2048 (RFC 7518 3.3).
const int minRsaModulusBits = 2048;

const Set<String> _privateRsaMembers = {'d', 'p', 'q', 'dp', 'dq', 'qi'};

/// [jwk]'s modulus and exponent when it is a public RSA key of at least [minRsaModulusBits] bits
/// (`kty` RSA, `n` and `e` base64url, no private member), else null (since the release after
/// 0.25.0).
(BigInt, BigInt)? publicRsaKey(Object? jwk) {
  if (jwk is! Map<Object?, Object?> || jwk['kty'] != 'RSA') return null;
  if (_privateRsaMembers.any(jwk.containsKey)) return null;
  final n = jwk['n'];
  final e = jwk['e'];
  if (n is! String || e is! String) return null;
  try {
    final modulus = _int(base64UrlDecodeLoose(n));
    final exponent = _int(base64UrlDecodeLoose(e));
    if (modulus.bitLength < minRsaModulusBits || exponent < BigInt.from(3)) {
      return null;
    }
    return (modulus, exponent);
  } on FormatException {
    return null;
  }
}

/// Whether [signature] is the RS256 signature (RSASSA-PKCS1-v1_5 with SHA-256, RFC 7518 3.3) of
/// [signingInput] by the public key [jwk] (since the release after 0.25.0). For an issuer's
/// attestation: a device never signs RS256.
///
/// False, never a throw, for anything wrong: a [jwk] that [publicRsaKey] refuses, a signature
/// that is not the modulus's length, or one that does not verify. Pure Dart (pointycastle).
bool verifyRs256(Object? jwk, List<int> signingInput, List<int> signature) {
  final key = publicRsaKey(jwk);
  if (key == null) return false;
  final (modulus, exponent) = key;
  if (signature.length != (modulus.bitLength + 7) ~/ 8) return false;
  final verifier = pc.RSASigner(pc.SHA256Digest(), _sha256DigestInfo)
    ..init(
      false,
      pc.PublicKeyParameter<pc.RSAPublicKey>(
        pc.RSAPublicKey(modulus, exponent),
      ),
    );
  try {
    return verifier.verifySignature(
      Uint8List.fromList(signingInput),
      pc.RSASignature(Uint8List.fromList(signature)),
    );
  } on Object {
    // A malformed block: the signature does not verify.
    return false;
  }
}

BigInt _int(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}
