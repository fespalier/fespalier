import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'cbor.dart';
import 'errors.dart';
import 'header.dart';

/// The RFC 9679 thumbprint of an EC2 P-256 key: `SHA-256` of the deterministic CBOR COSE_Key
/// holding only its required parameters, `{1: 2, -1: 1, -2: x, -3: y}` (map order by encoded
/// key: `01`, `20`, `21`, `22`). [x] and [y] are the 32-byte coordinates.
Uint8List ec2P256Thumbprint(List<int> x, List<int> y) {
  if (x.length != 32 || y.length != 32) {
    throw const CoseMisuse('a P-256 coordinate is 32 bytes');
  }
  final key = CborWriter()
    ..head(majorMap, 4)
    ..rawBytes(const [0x01, 0x02, 0x20, 0x01, 0x21])
    ..bstr(x)
    ..raw(0x22)
    ..bstr(y);
  return Uint8List.fromList(sha256.convert(key.toBytes()).bytes);
}

/// The `kid` of a thumbprint: its first 8 bytes. A collision is possible at about 2^32 keys, so
/// the thumbprint, not the `kid`, names a key unambiguously.
Uint8List kidFromThumbprint(List<int> thumbprint) =>
    Uint8List.fromList(thumbprint.sublist(0, kidLength));

/// The coordinates of a P-256 public JWK (`{kty: EC, crv: P-256, x, y}`, unpadded base64url),
/// as `fespalier_sign_keypair`'s `DpopSigner.publicJwk` answers.
({Uint8List x, Uint8List y}) p256CoordinatesOfJwk(Map<String, String> jwk) {
  if (jwk['kty'] != 'EC' || jwk['crv'] != 'P-256') {
    throw const CoseMisuse('the key is not a P-256 EC key');
  }
  Uint8List coordinate(String name) {
    final raw = jwk[name];
    if (raw == null) throw CoseMisuse('the JWK has no "$name"');
    final bytes = base64Url.decode(base64Url.normalize(raw));
    if (bytes.length != 32) throw CoseMisuse('JWK "$name" is not 32 bytes');
    return Uint8List.fromList(bytes);
  }

  return (x: coordinate('x'), y: coordinate('y'));
}
