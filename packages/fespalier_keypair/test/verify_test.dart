import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_keypair/verify.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final input = Uint8List.fromList(utf8.encode('header.payload'));

  group('verifyEs256', () {
    test('accepts a signature of the key that made it', () async {
      final signer = FakeKeypairSigner();
      final jwk = await signer.publicJwk();
      final signature = await signer.sign(input);
      expect(verifyEs256(jwk, input, signature), isTrue);
    });

    test('refuses another input, another key and another length', () async {
      final signer = FakeKeypairSigner();
      final jwk = await signer.publicJwk();
      final signature = await signer.sign(input);
      expect(
        verifyEs256(jwk, utf8.encode('header.payloaD'), signature),
        isFalse,
      );
      final other = await FakeKeypairSigner(seed: 'another').publicJwk();
      expect(verifyEs256(other, input, signature), isFalse);
      expect(verifyEs256(jwk, input, signature.sublist(1)), isFalse);
      expect(verifyEs256(jwk, input, Uint8List(64)), isFalse);
    });

    test('is false, not a throw, for a jwk that is not a public key', () async {
      final signer = FakeKeypairSigner();
      final signature = await signer.sign(input);
      expect(verifyEs256(null, input, signature), isFalse);
      expect(verifyEs256('x', input, signature), isFalse);
      expect(verifyEs256(const <String, String>{}, input, signature), isFalse);
    });
  });

  group('publicP256Jwk', () {
    test('returns the four members of a public P-256 key', () {
      expect(publicP256Jwk({...fakeJwk0, 'use': 'sig'}), fakeJwk0);
    });

    test(
      'refuses a private key, another curve, a bad size and an off-curve point',
      () {
        expect(publicP256Jwk({...fakeJwk0, 'd': 'AAAA'}), isNull);
        expect(publicP256Jwk({...fakeJwk0, 'crv': 'P-384'}), isNull);
        expect(publicP256Jwk({...fakeJwk0, 'kty': 'OKP'}), isNull);
        expect(publicP256Jwk({...fakeJwk0, 'x': 'AAAA'}), isNull);
        expect(publicP256Jwk({...fakeJwk0, 'x': '***'}), isNull);
        expect(publicP256Jwk({...fakeJwk0, 'y': fakeJwk0['x']}), isNull);
        expect(publicP256Jwk(<String, Object?>{'kty': 'EC'}), isNull);
        expect(publicP256Jwk(42), isNull);
      },
    );
  });
}
