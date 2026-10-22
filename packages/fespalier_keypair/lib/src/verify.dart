import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'jose.dart';

final pc.ECDomainParameters _domain = pc.ECDomainParameters('prime256v1');

// P-256's field prime and b (FIPS 186-4 D.1.2.3); a is -3.
final BigInt _p = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final BigInt _b = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);

/// [jwk] as `{crv, kty, x, y}` when it is a public P-256 key on the curve, else null (since
/// 0.21.0; the check `verifyDpopProof` made, lifted here): another curve or key type, a private
/// key (a `d` member), coordinates that are not 32 bytes of base64url, or a point off the curve.
///
/// Pure Dart, no plugin: a server and a test use it on a `jwk` they received.
Map<String, String>? publicP256Jwk(Object? jwk) => _point(jwk) == null
    ? null
    : <String, String>{
        'crv': 'P-256',
        'kty': 'EC',
        'x': (jwk! as Map<Object?, Object?>)['x']! as String,
        'y': (jwk as Map<Object?, Object?>)['y']! as String,
      };

/// Whether [signature] is the ES256 signature of [signingInput] by the key [jwk] (since 0.21.0;
/// lifted from `verifyDpopProof`): a 64-byte IEEE P1363 `r||s` over SHA-256 of the input, which
/// is what every `KeypairSigner` makes and a JWS carries.
///
/// False, never a throw, for anything wrong: a [jwk] that [publicP256Jwk] refuses, a signature
/// of another length, or one that does not verify. Pure Dart.
bool verifyEs256(Object? jwk, List<int> signingInput, List<int> signature) {
  final point = _point(jwk);
  if (point == null || signature.length != 64) return false;
  final verifier = pc.ECDSASigner(pc.SHA256Digest())
    ..init(
      false,
      pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(point, _domain)),
    );
  try {
    return verifier.verifySignature(
      Uint8List.fromList(signingInput),
      pc.ECSignature(
        _int(signature.sublist(0, 32)),
        _int(signature.sublist(32)),
      ),
    );
  } on Object {
    // A degenerate r or s: the signature does not verify.
    return false;
  }
}

pc.ECPoint? _point(Object? jwk) {
  if (jwk is! Map<Object?, Object?>) return null;
  if (jwk['kty'] != 'EC' || jwk['crv'] != 'P-256' || jwk.containsKey('d')) {
    return null;
  }
  final x = jwk['x'];
  final y = jwk['y'];
  if (x is! String || y is! String) return null;
  final Uint8List xb;
  final Uint8List yb;
  try {
    xb = base64UrlDecodeLoose(x);
    yb = base64UrlDecodeLoose(y);
  } on FormatException {
    return null;
  }
  if (xb.length != 32 || yb.length != 32) return null;
  final xi = _int(xb);
  final yi = _int(yb);
  if (xi >= _p || yi >= _p) return null;
  final left = (yi * yi) % _p;
  final right = (xi * xi * xi - BigInt.from(3) * xi + _b) % _p;
  if (left != right) return null;
  return _domain.curve.createPoint(xi, yi);
}

BigInt _int(List<int> bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}
