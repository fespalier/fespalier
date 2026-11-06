// verifyEd25519 against RFC 8032's own test vectors, and verifyRs256 against signatures
// pointycastle makes with a key generated here. The profile v1 conformance vectors, which carry
// an EdDSA and an RS256 issuer, run in fespalier_sign_keypair.
import 'dart:math';
import 'dart:typed_data';

import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/verify.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

Map<String, String> _okp(String publicHex) => {
  'kty': 'OKP',
  'crv': 'Ed25519',
  'x': base64UrlNoPad(_hex(publicHex)),
};

Uint8List _bytes(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

void main() {
  group('verifyEd25519', () {
    // RFC 8032 section 7.1, TEST 1 (the empty message) and TEST 2 (one byte, 0x72).
    final key1 = _okp(
      'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    );
    final sig1 = _hex(
      'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
      '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
    );
    final key2 = _okp(
      '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
    );
    final sig2 = _hex(
      '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
      '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
    );

    test("accepts RFC 8032's signatures", () {
      expect(verifyEd25519(key1, const [], sig1), isTrue);
      expect(verifyEd25519(key2, const [0x72], sig2), isTrue);
    });

    test('refuses another message, another key, and a changed signature', () {
      expect(verifyEd25519(key1, const [0], sig1), isFalse);
      expect(verifyEd25519(key2, const [], sig1), isFalse);
      expect(
        verifyEd25519(key1, const [], Uint8List.fromList(sig1)..[5] ^= 1),
        isFalse,
      );
      expect(verifyEd25519(key1, const [], sig1.sublist(1)), isFalse);
    });

    test('refuses S at or above the group order (malleability)', () {
      // S + L for TEST 1: the same point equation, a non-canonical scalar.
      final l =
          (BigInt.one << 252) +
          BigInt.parse('27742317777372353535851937790883648493');
      var s = BigInt.zero;
      for (var i = 63; i >= 32; i--) {
        s = (s << 8) | BigInt.from(sig1[i]);
      }
      final bigger = _bytes(s + l, 32).reversed.toList();
      final forged = Uint8List.fromList([...sig1.sublist(0, 32), ...bigger]);
      expect(verifyEd25519(key1, const [], forged), isFalse);
    });

    test('refuses a small-order key and a non-canonical one', () {
      // The identity (y = 1) has order 1; y = p is not canonical.
      final identity = Uint8List(32)..[0] = 1;
      expect(
        verifyEd25519(
          {'kty': 'OKP', 'crv': 'Ed25519', 'x': base64UrlNoPad(identity)},
          const [],
          sig1,
        ),
        isFalse,
      );
      final p = _bytes((BigInt.one << 255) - BigInt.from(19), 32).reversed;
      expect(
        verifyEd25519(
          {
            'kty': 'OKP',
            'crv': 'Ed25519',
            'x': base64UrlNoPad([...p]),
          },
          const [],
          sig1,
        ),
        isFalse,
      );
    });

    test('is false, not a throw, for what is not a public Ed25519 key', () {
      expect(verifyEd25519(null, const [], sig1), isFalse);
      expect(verifyEd25519({...key1, 'd': 'AAAA'}, const [], sig1), isFalse);
      expect(
        verifyEd25519({...key1, 'crv': 'X25519'}, const [], sig1),
        isFalse,
      );
      expect(verifyEd25519({...key1, 'x': 'AAAA'}, const [], sig1), isFalse);
      expect(publicEd25519Key(key1), hasLength(32));
    });

    test('jwkThumbprint reads an Ed25519 key (RFC 8037 appendix A.3)', () {
      expect(
        jwkThumbprint(const {
          'kty': 'OKP',
          'crv': 'Ed25519',
          'x': '11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo',
        }),
        'kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k',
      );
    });
  });

  group('verifyRs256', () {
    late pc.RSAPublicKey public;
    late pc.RSAPrivateKey private;
    final input = Uint8List.fromList('header.payload'.codeUnits);

    setUpAll(() {
      final random = pc.FortunaRandom()
        ..seed(
          pc.KeyParameter(
            Uint8List.fromList(
              List.generate(32, (i) => Random(7).nextInt(256)),
            ),
          ),
        );
      final generator = pc.RSAKeyGenerator()
        ..init(
          pc.ParametersWithRandom(
            pc.RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
            random,
          ),
        );
      final pair = generator.generateKeyPair();
      public = pair.publicKey;
      private = pair.privateKey;
    });

    Map<String, String> jwk() => {
      'kty': 'RSA',
      'n': base64UrlNoPad(_bytes(public.modulus!, 256)),
      'e': base64UrlNoPad(_bytes(public.exponent!, 3)),
    };

    Uint8List sign(List<int> data) {
      final signer = pc.RSASigner(pc.SHA256Digest(), '0609608648016503040201')
        ..init(true, pc.PrivateKeyParameter<pc.RSAPrivateKey>(private));
      return signer.generateSignature(Uint8List.fromList(data)).bytes;
    }

    test('accepts a signature of the key that made it', () {
      expect(verifyRs256(jwk(), input, sign(input)), isTrue);
    });

    test('refuses another input, a changed signature and a short one', () {
      final signature = sign(input);
      expect(verifyRs256(jwk(), [...input, 0], signature), isFalse);
      expect(
        verifyRs256(jwk(), input, Uint8List.fromList(signature)..[9] ^= 1),
        isFalse,
      );
      expect(verifyRs256(jwk(), input, signature.sublist(1)), isFalse);
    });

    test('refuses a private key, a short modulus and what is not RSA', () {
      final signature = sign(input);
      expect(verifyRs256({...jwk(), 'd': 'AAAA'}, input, signature), isFalse);
      expect(
        verifyRs256(
          {...jwk(), 'n': base64UrlNoPad(Uint8List(128)..[0] = 0xc1)},
          input,
          signature,
        ),
        isFalse,
      );
      expect(verifyRs256({...jwk(), 'kty': 'EC'}, input, signature), isFalse);
      expect(verifyRs256(42, input, signature), isFalse);
    });
  });
}
