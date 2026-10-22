import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:pointycastle/export.dart' as pc;

/// What Python's `cryptography` and `hashlib` say about [FakeKeypairSigner]'s keys: see the
/// comment in thumbprint_test.dart for how they were made.
const fakeJwk0 = <String, String>{
  'crv': 'P-256',
  'kty': 'EC',
  'x': 'WNEwJCFUdZpTU1Rb5Eec1I7dH3bcfk45js5xgyO_gsI',
  'y': 'BzhZPASdZG_6zkhHdtFgJPlQay4yEmAxf2CpkNA47p4',
};
const fakeThumbprint0 = 'XCW8GJrJxRT2sQyX29vGikHXwr7aK5puMdwvhd9pqNE';
const fakeThumbprint1 = 'kSFjtX3PWG7XxFarb-p54ae5WE7C7nIbuoo5V2zbE20';

/// Whether [signature] (64 bytes, r||s) is [jwk]'s ES256 signature of [input]: what a server
/// does, here for the tests to check a signer with.
bool verifiesEs256(
  Map<String, String> jwk,
  List<int> input,
  Uint8List signature,
) {
  final domain = pc.ECDomainParameters('prime256v1');
  BigInt bigInt(List<int> bytes) =>
      bytes.fold(BigInt.zero, (a, b) => (a << 8) | BigInt.from(b));
  final point = domain.curve.createPoint(
    bigInt(base64UrlDecodeLoose(jwk['x']!)),
    bigInt(base64UrlDecodeLoose(jwk['y']!)),
  );
  final verifier = pc.ECDSASigner(pc.SHA256Digest())
    ..init(
      false,
      pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(point, domain)),
    );
  return signature.length == 64 &&
      verifier.verifySignature(
        Uint8List.fromList(input),
        pc.ECSignature(
          bigInt(signature.sublist(0, 32)),
          bigInt(signature.sublist(32)),
        ),
      );
}

/// The JSON object of part [index] of a compact JWS.
Map<String, Object?> part(String jws, int index) =>
    jsonDecode(utf8.decode(base64UrlDecodeLoose(jws.split('.')[index])))
        as Map<String, Object?>;

/// The SHA-256 of [text] as lower-case hex.
String sha256Hex(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();
