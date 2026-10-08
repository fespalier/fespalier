import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cose_example/src/cose/cose.dart';
import 'package:crypto/crypto.dart';

/// Hex to bytes.
Uint8List unhex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

/// Bytes to lowercase hex.
String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// `test_vectors/<name>`, parsed.
Map<String, Object?> loadVectors(String name) {
  final text = File('test_vectors/$name').readAsStringSync();
  return jsonDecode(text) as Map<String, Object?>;
}

/// The binding a vector names.
CoseBinding bindingOf(Map<String, Object?> json) {
  final headers = json['bound_headers']! as Map<String, Object?>;
  final kind = json['request_kind'] as int?;
  return CoseBinding(
    audience: json['audience']! as String,
    method: json['method']! as String,
    route: json['route']! as String,
    pathParams: (json['path_params']! as List<Object?>).cast<String>(),
    query: json['query'] as String?,
    contractSha: unhex(json['contract_sha']! as String),
    payloadType: json['payload_type']! as String,
    idempotencyKey: headers['idempotency_key'] as String?,
    ifMatch: headers['if_match'] as String?,
    response: kind == null
        ? null
        : ResponseLink(
            requestKind: kind,
            requestDigest: unhex(json['request_digest']! as String),
            status: json['status']! as int,
          ),
  );
}

/// An Ed25519 verification key (RFC 8032, PureEdDSA), in the tests only: the library speaks
/// ESP256, and pointycastle has no Ed25519. It lets the Ed25519 vectors prove the opener's
/// shape, AAD and header checks, which do not depend on the algorithm.
final class TestEd25519Key implements CoseVerifyKey {
  TestEd25519Key(this.kid, this._public);

  @override
  final Uint8List kid;
  final Uint8List _public;

  @override
  int get alg => algEd25519;

  @override
  bool verify(Uint8List toBeSigned, Uint8List signature) =>
      ed25519Verify(_public, toBeSigned, signature);
}

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = (-BigInt.from(121665) * _inv(BigInt.from(121666))) % _p;

BigInt _inv(BigInt a) => a.modPow(_p - BigInt.two, _p);

typedef _Pt = (BigInt, BigInt);

_Pt _add(_Pt a, _Pt b) {
  final x1y2 = a.$1 * b.$2;
  final x2y1 = b.$1 * a.$2;
  final dxy = _d * a.$1 * b.$1 * a.$2 * b.$2;
  final x = (x1y2 + x2y1) * _inv(BigInt.one + dxy) % _p;
  final y = (a.$2 * b.$2 + a.$1 * b.$1) * _inv(BigInt.one - dxy) % _p;
  return (x, y);
}

_Pt _mul(_Pt point, BigInt k) {
  _Pt acc = (BigInt.zero, BigInt.one);
  _Pt addend = point;
  var rest = k;
  while (rest > BigInt.zero) {
    if (rest.isOdd) acc = _add(acc, addend);
    addend = _add(addend, addend);
    rest >>= 1;
  }
  return acc;
}

BigInt _leInt(List<int> bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

_Pt? _decode(Uint8List bytes) {
  if (bytes.length != 32) return null;
  final sign = bytes[31] >> 7;
  final y = _leInt(bytes) & ((BigInt.one << 255) - BigInt.one);
  if (y >= _p) return null;
  final y2 = y * y % _p;
  final x2 = (y2 - BigInt.one) * _inv(_d * y2 + BigInt.one) % _p;
  var x = x2.modPow((_p + BigInt.from(3)) >> 3, _p);
  if ((x * x - x2) % _p != BigInt.zero) {
    x = x * BigInt.two.modPow((_p - BigInt.one) >> 2, _p) % _p;
  }
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if (x.isOdd != (sign == 1)) x = (_p - x) % _p;
  return (x, y);
}

/// RFC 8032 §5.1.7 verification (cofactorless).
bool ed25519Verify(Uint8List publicKey, Uint8List message, Uint8List sig) {
  if (sig.length != 64) return false;
  final a = _decode(publicKey);
  final r = _decode(Uint8List.sublistView(sig, 0, 32));
  if (a == null || r == null) return false;
  final s = _leInt(sig.sublist(32));
  if (s >= _l) return false;
  final h =
      _leInt(
        sha512.convert([...sig.sublist(0, 32), ...publicKey, ...message]).bytes,
      ) %
      _l;
  final base = _decode(
    unhex('5866666666666666666666666666666666666666666666666666666666666666'),
  )!;
  final left = _mul(base, s);
  final right = _add(r, _mul(a, h));
  return left.$1 == right.$1 && left.$2 == right.$2;
}

/// The verify key a `keys.json` entry names, or null for a key this library cannot verify with
/// (HMAC).
CoseVerifyKey? verifyKeyNamed(String name, Map<String, Object?> keys) {
  final entry = keys[name]! as Map<String, Object?>;
  switch (entry['alg']) {
    case -9:
      return Esp256VerifyKey.sec1(
        unhex(entry['public_sec1_uncompressed']! as String),
      );
    case -19:
      return TestEd25519Key(
        unhex(entry['kid']! as String),
        unhex(entry['public']! as String),
      );
  }
  return null;
}
