import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'errors.dart';
import 'header.dart';
import 'thumbprint.dart';

final pc.ECDomainParameters _p256 = pc.ECDomainParameters('prime256v1');

BigInt _int(List<int> bytes) {
  var value = BigInt.zero;
  for (final byte in bytes) {
    value = (value << 8) | BigInt.from(byte);
  }
  return value;
}

Uint8List _bytes32(BigInt value) {
  final out = Uint8List(32);
  var rest = value;
  final mask = BigInt.from(0xff);
  for (var i = 31; i >= 0; i--) {
    out[i] = (rest & mask).toInt();
    rest >>= 8;
  }
  return out;
}

/// Normalises an ESP256 signature (64 bytes, `r||s`) to low-s: `s` above `n/2` becomes `n - s`.
///
/// cratestack's verifier refuses a high `s` (`neg-esp256-high-s`), and neither ECDSA nor the
/// platform signers promise a low one, so a sender always normalises. A signature whose `r` or
/// `s` is zero or not below the curve order is [CoseMisuse].
Uint8List normalizeLowS(Uint8List signature) {
  if (signature.length != 64) {
    throw const CoseMisuse('an ESP256 signature is 64 bytes');
  }
  final n = _p256.n;
  final r = _int(signature.sublist(0, 32));
  final s = _int(signature.sublist(32));
  if (r == BigInt.zero || r >= n || s == BigInt.zero || s >= n) {
    throw const CoseMisuse('the signer returned an invalid ESP256 signature');
  }
  final low = s > (n >> 1) ? n - s : s;
  return Uint8List(64)
    ..setRange(0, 32, signature, 0)
    ..setRange(32, 64, _bytes32(low));
}

/// A key that verifies COSE_Sign1 signatures of one algorithm.
abstract interface class CoseVerifyKey {
  /// The COSE algorithm id this key verifies (and only that one).
  int get alg;

  /// The 8-byte `kid`.
  Uint8List get kid;

  /// Whether [signature] is valid over [toBeSigned] (the Sig_structure).
  bool verify(Uint8List toBeSigned, Uint8List signature);
}

/// A P-256 public key for ESP256 (ECDSA with SHA-256, 64-byte `r||s`).
///
/// Like cratestack's verifier it refuses a high `s`: a message with one is not accepted, even
/// though it verifies mathematically.
final class Esp256VerifyKey implements CoseVerifyKey {
  Esp256VerifyKey._(this._key, this.thumbprint)
    : kid = kidFromThumbprint(thumbprint);

  /// From the uncompressed SEC1 point (`04 || x || y`, 65 bytes).
  factory Esp256VerifyKey.sec1(List<int> point) {
    if (point.length != 65 || point[0] != 0x04) {
      throw ArgumentError.value(
        point.length,
        'point',
        'not an uncompressed point',
      );
    }
    final q = _p256.curve.decodePoint(point);
    if (q == null || q.isInfinity) {
      throw ArgumentError.value(point, 'point', 'not a point of P-256');
    }
    return Esp256VerifyKey._(
      pc.ECPublicKey(q, _p256),
      ec2P256Thumbprint(point.sublist(1, 33), point.sublist(33)),
    );
  }

  /// From a public JWK (`{kty: EC, crv: P-256, x, y}`).
  factory Esp256VerifyKey.jwk(Map<String, String> jwk) {
    final c = p256CoordinatesOfJwk(jwk);
    return Esp256VerifyKey.sec1([0x04, ...c.x, ...c.y]);
  }

  final pc.ECPublicKey _key;

  /// The RFC 9679 thumbprint (32 bytes).
  final Uint8List thumbprint;

  @override
  final Uint8List kid;

  @override
  int get alg => algEsp256;

  @override
  bool verify(Uint8List toBeSigned, Uint8List signature) {
    if (signature.length != 64) return false;
    final r = _int(signature.sublist(0, 32));
    final s = _int(signature.sublist(32));
    final n = _p256.n;
    if (r == BigInt.zero || r >= n || s == BigInt.zero || s > (n >> 1)) {
      return false;
    }
    final verifier = pc.ECDSASigner(pc.SHA256Digest())
      ..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(_key));
    try {
      return verifier.verifySignature(toBeSigned, pc.ECSignature(r, s));
    } on Object {
      return false;
    }
  }
}
