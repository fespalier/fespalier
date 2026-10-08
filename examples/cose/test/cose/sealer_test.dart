import 'dart:typed_data';

import 'package:cose_example/src/cose/cose.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

CoseBinding _binding({String audience = 'demo', String? idempotencyKey}) =>
    CoseBinding(
      audience: audience,
      method: 'POST',
      route: 'procedure.addNote',
      contractSha: Uint8List(32)..fillRange(0, 32, 7),
      idempotencyKey: idempotencyKey,
    );

/// Signs like a signer that does not promise low-s: it flips to the high twin half the time.
final class _HighSSigner implements DpopSigner {
  _HighSSigner(this._inner);
  final DpopSigner _inner;

  @override
  Future<Map<String, String>> publicJwk() => _inner.publicJwk();

  @override
  Future<Uint8List> sign(Uint8List signingInput) async {
    final low = normalizeLowS(await _inner.sign(signingInput));
    // n - s, on the 32-byte big-endian s.
    final n = BigInt.parse(
      'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
      radix: 16,
    );
    var s = BigInt.zero;
    for (final b in low.sublist(32)) {
      s = (s << 8) | BigInt.from(b);
    }
    var high = n - s;
    final out = Uint8List.fromList(low);
    for (var i = 63; i >= 32; i--) {
      out[i] = (high & BigInt.from(0xff)).toInt();
      high >>= 8;
    }
    return out;
  }

  @override
  Future<bool> isHardwareBacked() => _inner.isHardwareBacked();

  @override
  Future<void> deleteKey() => _inner.deleteKey();
}

void main() {
  test('a request seals and opens with the signer\'s own key', () async {
    final signer = FakeDpopSigner();
    final sealer = CoseSealer(signer, nowSeconds: () => 1790000000);
    final me = await sealer.identity();
    final bind = _binding(idempotencyKey: 'intent-1#0');
    final sealed = await sealer.sealRequest([1, 2, 3], bind);
    final opened = CoseOpener([
      me,
    ], nowSeconds: () => 1790000000).openRequest(sealed, bind);
    expect(opened.payload, [1, 2, 3]);
    expect(opened.iat, 1790000000);
    expect(opened.cti, hasLength(16));
    expect(hex(opened.kid), hex(me.kid));
  });

  test(
    'every request gets a fresh cti, and none is opened for another binding',
    () async {
      final sealer = CoseSealer(FakeDpopSigner());
      final bind = _binding();
      final a = await sealer.sealRequest([1], bind);
      final b = await sealer.sealRequest([1], bind);
      expect(hex(a), isNot(hex(b)));
      final me = await sealer.identity();
      final opener = CoseOpener([me]);
      // The Idempotency-Key is bound: a request sealed without one is not the request that
      // asked for one.
      expect(
        () => opener.openRequest(a, _binding(idempotencyKey: 'x')),
        throwsA(isA<CoseRejected>()),
      );
      expect(
        () => opener.openRequest(a, _binding(audience: 'other')),
        throwsA(isA<CoseRejected>()),
      );
    },
  );

  test(
    'a high-s signature from the signer is sent as low-s and verifies',
    () async {
      final sealer = CoseSealer(_HighSSigner(FakeDpopSigner()));
      final bind = _binding();
      final sealed = await sealer.sealRequest([9], bind);
      final me = await sealer.identity();
      CoseOpener([me]).openRequest(sealed, bind);
      final s = sealed.sublist(sealed.length - 32);
      expect(
        s[0] < 0x80,
        isTrue,
        reason: 'low-s is below n/2, so the top bit is clear',
      );
    },
  );

  test('the verifier refuses a high-s signature the signer produced', () async {
    // The twin of a valid signature is refused even though it verifies mathematically.
    final signer = _HighSSigner(FakeDpopSigner());
    final me = Esp256VerifyKey.jwk(await signer.publicJwk());
    final tbs = Uint8List.fromList([1, 2, 3]);
    final high = await signer.sign(tbs);
    expect(me.verify(tbs, high), isFalse);
    expect(me.verify(tbs, normalizeLowS(high)), isTrue);
  });

  test('misuse is found before anything is signed', () async {
    final signer = FakeDpopSigner();
    final sealer = CoseSealer(signer);
    await expectLater(
      sealer.sealRequest([1], _binding(audience: '')),
      throwsA(isA<CoseMisuse>()),
    );
    await expectLater(
      sealer.sealRequest([1], _binding(), cti: Uint8List(5)),
      throwsA(isA<CoseMisuse>()),
    );
    expect(signer.signatures, 0);
  });

  test(
    'the kid is the first 8 bytes of the key\'s RFC 9679 thumbprint',
    () async {
      final signer = FakeDpopSigner();
      final jwk = await signer.publicJwk();
      final c = p256CoordinatesOfJwk(jwk);
      final thumb = ec2P256Thumbprint(c.x, c.y);
      final me = await CoseSealer(signer).identity();
      expect(hex(me.thumbprint), hex(thumb));
      expect(hex(me.kid), hex(thumb.sublist(0, 8)));
    },
  );

  test('a secure cti is 16 bytes and differs between calls', () {
    expect(secureCti(), hasLength(16));
    expect(hex(secureCti()), isNot(hex(secureCti())));
  });
}
