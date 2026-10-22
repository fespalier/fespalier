import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A signer that returns whatever it is given.
final class _Raw implements KeypairSigner {
  _Raw(this.bytes);

  final Uint8List bytes;

  @override
  KeyRole get role => KeyRole.ambient;

  @override
  Future<Map<String, String>> publicJwk() async => const {};

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) async =>
      bytes;

  @override
  Future<bool> isHardwareBacked() async => false;

  @override
  Future<bool> exists() async => true;

  @override
  Future<void> deleteKey() async {}
}

void main() {
  group('base64url', () {
    test('has no padding, and uses - and _', () {
      expect(base64UrlNoPad([0xfb, 0xff]), '-_8');
      expect(base64UrlNoPad([1]), 'AQ');
      expect(base64UrlNoPad(const []), '');
    });

    test('decodes with or without padding', () {
      expect(base64UrlDecodeLoose('-_8'), [0xfb, 0xff]);
      expect(base64UrlDecodeLoose('-_8='), [0xfb, 0xff]);
      expect(base64UrlDecodeLoose('AQ'), [1]);
    });
  });

  group('compactJws', () {
    test(
      'is header.payload.signature, signed over the first two parts',
      () async {
        final signer = FakeKeypairSigner();
        final jwk = await signer.publicJwk();
        final jws = await compactJws(
          {'alg': 'ES256', 'typ': 'JWT', 'jwk': jwk},
          {'iat': 1791028800, 'sub': 'device'},
          signer,
        );
        final parts = jws.split('.');
        expect(parts, hasLength(3));
        expect(part(jws, 0), {'alg': 'ES256', 'typ': 'JWT', 'jwk': jwk});
        expect(part(jws, 1), {'iat': 1791028800, 'sub': 'device'});
        expect(
          verifiesEs256(
            jwk,
            utf8.encode('${parts[0]}.${parts[1]}'),
            base64UrlDecodeLoose(parts[2]),
          ),
          isTrue,
        );
        expect(jws, isNot(contains('=')));
      },
    );

    test('keeps the order of the members it is given', () async {
      final jws = await compactJws(
        {'typ': 'JWT', 'alg': 'ES256'},
        {'b': 1, 'a': 2},
        FakeKeypairSigner(),
      );
      final parts = jws.split('.');
      expect(
        utf8.decode(base64UrlDecodeLoose(parts[0])),
        '{"typ":"JWT","alg":"ES256"}',
      );
      expect(utf8.decode(base64UrlDecodeLoose(parts[1])), '{"b":1,"a":2}');
    });

    test('hands the reason to a prompting key', () async {
      final signer = FakeKeypairSigner(role: KeyRole.userPresent);
      await compactJws(
        {'alg': 'ES256'},
        {},
        signer,
        reason: 'Confirm the transfer',
      );
      expect(signer.lastReason, 'Confirm the transfer');
      expect(signer.prompts, 1);
    });

    test('refuses a signature that is not 64 bytes', () async {
      await expectLater(
        compactJws({'alg': 'ES256'}, {}, _Raw(Uint8List(70))),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'fespalier_keypair: the signer returned 70 bytes, not the 64-byte r||s '
                'signature that ES256 needs',
          ),
        ),
      );
    });
  });
}
