import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'jose.dart';

// Ed25519 verification (RFC 8032 section 5.1.7) in pure Dart, over BigInt: no plugin and no new
// dependency (pointycastle has no Edwards curve). It is for servers, demo servers and tests, which
// verify a handful of signatures; it is not constant-time, which a verifier of public data does
// not need. Strict, as `ed25519-dalek`'s `verify_strict` (what Authkestra's profile v1 asks for):
// a non-canonical point or scalar, and a small-order public key or R, are refused.

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d =
    (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final BigInt _sqrtM1 = BigInt.two.modPow(
  (_p - BigInt.one) ~/ BigInt.from(4),
  _p,
);

/// A point in extended coordinates (X, Y, Z, T), x = X/Z, y = Y/Z, xy = T/Z.
typedef _Point = (BigInt, BigInt, BigInt, BigInt);

final _Point _identity = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

final _Point _base = () {
  final y = (BigInt.from(4) * BigInt.from(5).modInverse(_p)) % _p;
  final x = _recoverX(y, 0)!;
  return (x, y, BigInt.one, (x * y) % _p);
}();

BigInt? _recoverX(BigInt y, int sign) {
  if (y >= _p) return null;
  final y2 = (y * y) % _p;
  final x2 = ((y2 - BigInt.one) * (_d * y2 + BigInt.one).modInverse(_p)) % _p;
  if (x2 == BigInt.zero) return sign == 0 ? BigInt.zero : null;
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if (x.isOdd != (sign == 1)) x = _p - x;
  return x;
}

_Point _add(_Point a, _Point b) {
  final pa = (a.$2 - a.$1) * (b.$2 - b.$1) % _p;
  final pb = (a.$2 + a.$1) * (b.$2 + b.$1) % _p;
  final c = BigInt.two * a.$4 * b.$4 * _d % _p;
  final dd = BigInt.two * a.$3 * b.$3 % _p;
  final e = pb - pa;
  final f = dd - c;
  final g = dd + c;
  final h = pb + pa;
  return (e * f % _p, g * h % _p, f * g % _p, e * h % _p);
}

_Point _mul(BigInt scalar, _Point point) {
  var result = _identity;
  var addend = point;
  var s = scalar;
  while (s > BigInt.zero) {
    if (s.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    s >>= 1;
  }
  return result;
}

bool _equal(_Point a, _Point b) =>
    (a.$1 * b.$3 - b.$1 * a.$3) % _p == BigInt.zero &&
    (a.$2 * b.$3 - b.$2 * a.$3) % _p == BigInt.zero;

BigInt _littleEndian(List<int> bytes) {
  var result = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    result = (result << 8) | BigInt.from(bytes[i]);
  }
  return result;
}

_Point? _decode(List<int> bytes) {
  if (bytes.length != 32) return null;
  final copy = Uint8List.fromList(bytes);
  final sign = copy[31] >> 7;
  copy[31] &= 0x7f;
  final y = _littleEndian(copy);
  final x = _recoverX(y, sign);
  if (x == null) return null;
  return (x, y, BigInt.one, (x * y) % _p);
}

bool _smallOrder(_Point point) =>
    _equal(_mul(BigInt.from(8), point), _identity);

/// The 32 bytes of the public key of [jwk] when it is a public Ed25519 key (`kty` OKP, `crv`
/// Ed25519, `x` of 32 bytes, no `d`), else null (since the release after 0.25.0).
Uint8List? publicEd25519Key(Object? jwk) {
  if (jwk is! Map<Object?, Object?>) return null;
  if (jwk['kty'] != 'OKP' || jwk['crv'] != 'Ed25519' || jwk.containsKey('d')) {
    return null;
  }
  final x = jwk['x'];
  if (x is! String) return null;
  try {
    final bytes = base64UrlDecodeLoose(x);
    return bytes.length == 32 ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// Whether [signature] is the Ed25519 signature (JWS `EdDSA`, RFC 8037) of [signingInput] by the
/// public key [jwk] (since the release after 0.25.0): 64 bytes `R || S`, checked strictly (a
/// non-canonical encoding, an `S` not below the group order, and a small-order key or `R` are
/// refused).
///
/// False, never a throw, for anything wrong: a [jwk] that [publicEd25519Key] refuses, a signature
/// of another length, or one that does not verify. Pure Dart, and slow next to a native library:
/// for a server, a demo server and a test, not for a hot path.
bool verifyEd25519(Object? jwk, List<int> signingInput, List<int> signature) {
  final key = publicEd25519Key(jwk);
  if (key == null || signature.length != 64) return false;
  final a = _decode(key);
  final r = _decode(signature.sublist(0, 32));
  if (a == null || r == null || _smallOrder(a) || _smallOrder(r)) return false;
  final s = _littleEndian(signature.sublist(32));
  if (s >= _l) return false;
  final digest = sha512.convert([
    ...signature.sublist(0, 32),
    ...key,
    ...signingInput,
  ]);
  final k = _littleEndian(digest.bytes) % _l;
  return _equal(_mul(s, _base), _add(r, _mul(k, a)));
}
