// The vectors here were made without Dart:
//
// - RFC 9449 publishes the key of its examples (section 4.1) and its thumbprint (the `jkt` of
//   section 6.1, `0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I`), and the `ath` of its access token
//   (section 7.1).
// - The thumbprints of FakeDpopSigner's keys are python's hashlib over the canonical JSON, and
//   the keys themselves are python-cryptography's `derive_private_key(sha256(seed))`:
//
//     d = int.from_bytes(hashlib.sha256(b'fespalier_sign_keypair fake key').digest(), 'big')
//     nums = ec.derive_private_key(d, ec.SECP256R1()).public_key().public_numbers()
//     canonical = '{"crv":"P-256","kty":"EC","x":"%s","y":"%s"}' % (b64u(x), b64u(y))
//     b64u(hashlib.sha256(canonical.encode()).digest())
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  const rfcKey = <String, String>{
    'kty': 'EC',
    'x': 'l8tFrhx-34tV3hRICRDY9zCkDlpBhF42UQUfWVAWBFs',
    'y': '9VE4jf_Ok_o64zbTTlcuNJajHmt6v9TDVrU0CdvGRDA',
    'crv': 'P-256',
  };

  test("is the thumbprint RFC 9449 publishes for its example key", () {
    expect(
      jwkThumbprint(rfcKey),
      '0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I',
    );
  });

  test('is python hashlib for the fake keys', () async {
    final signer = FakeDpopSigner();
    expect(await signer.publicJwk(), fakeJwk0);
    expect(jwkThumbprint(await signer.publicJwk()), fakeThumbprint0);
    await signer.deleteKey();
    expect(jwkThumbprint(await signer.publicJwk()), fakeThumbprint1);
  });

  test(
    'uses crv, kty, x and y in that order, whatever order and extras the key has',
    () {
      final shuffled = <String, String>{
        'y': rfcKey['y']!,
        'kid': 'a-key-id',
        'kty': 'EC',
        'use': 'sig',
        'x': rfcKey['x']!,
        'alg': 'ES256',
        'crv': 'P-256',
      };
      expect(jwkThumbprint(shuffled), jwkThumbprint(rfcKey));
    },
  );

  test('refuses what is not an EC P-256 public key', () {
    for (final bad in <Map<String, Object?>>[
      {...rfcKey, 'crv': 'P-384'},
      {...rfcKey, 'kty': 'RSA'},
      {'kty': 'EC', 'crv': 'P-256', 'x': rfcKey['x']},
      {'kty': 'EC', 'crv': 'P-256', 'x': 1, 'y': rfcKey['y']},
      <String, Object?>{},
    ]) {
      expect(() => jwkThumbprint(bad), throwsArgumentError, reason: '$bad');
    }
  });

  test(
    'ath is the base64url SHA-256 of the ASCII token, as in RFC 9449 section 7.1',
    () {
      expect(
        accessTokenHash('Kz~8mXK1EalYznwH-LC-1fBAo.4Ljp~zsPE_NeO.gxU'),
        'fUHyO2r2Z3DZ53EsNrWBb0xWXoaNy59IiKCAqksmQEo',
      );
    },
  );
}
