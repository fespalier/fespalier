import 'dart:convert';

import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// RFC 9449 figure 13: a proof signed by the RFC's authors with their key. Verifying it checks the
/// ES256 verification against an implementation that is not ours.
const rfcProof =
    'eyJ0eXAiOiJkcG9wK2p3dCIsImFsZyI6IkVTMjU2IiwiandrIjp7Imt0eSI6IkVDIiwieCI6Imw4dEZyaHgtMzR0VjNoUklDUkRZOXpDa0RscEJoRjQyVVFVZldWQVdCRnMiLCJ5IjoiOVZFNGpmX09rX282NHpiVFRsY3VOSmFqSG10NnY5VERWclUwQ2R2R1JEQSIsImNydiI6IlAtMjU2In19.eyJqdGkiOiJlMWozVl9iS2ljOC1MQUVCIiwiaHRtIjoiR0VUIiwiaHR1IjoiaHR0cHM6Ly9yZXNvdXJjZS5leGFtcGxlLm9yZy9wcm90ZWN0ZWRyZXNvdXJjZSIsImlhdCI6MTU2MjI2MjYxOCwiYXRoIjoiZlVIeU8ycjJaM0RaNTNFc05yV0JiMHhXWG9hTnk1OUlpS0NBcWtzbVFFbyJ9.2oW9RP35yRqzhrtNP86L-Ey71EOptxRimPPToA1plemAgR6pxHF8y6-yqyVnmcw6Fy1dqd-jfxSYoMxhAJpLjA';
const rfcToken = 'Kz~8mXK1EalYznwH-LC-1fBAo.4Ljp~zsPE_NeO.gxU';
final rfcUri = Uri.parse('https://resource.example.org/protectedresource');
final rfcNow = DateTime.fromMillisecondsSinceEpoch(
  1562262618 * 1000,
  isUtc: true,
);

final uri = Uri.parse('https://api.example.com/orders?page=2');
const token = 'an-access-token';

void main() {
  late FakeDpopSigner signer;
  setUp(() => signer = FakeDpopSigner());

  Map<String, Object?> claims({
    String htm = 'GET',
    String? htu,
    Object? jti = 'a-jti',
    Object? iat,
    String? ath,
    String? nonce,
  }) => {
    'jti': ?jti,
    'htm': htm,
    'htu': htu ?? 'https://api.example.com/orders',
    'iat': iat ?? t0.millisecondsSinceEpoch ~/ 1000,
    'ath': ?ath,
    'nonce': ?nonce,
  };

  Future<String> proof({
    Map<String, Object?>? header,
    Map<String, Object?>? claims_,
  }) => signedProof(signer, header: header, claims: claims_ ?? claims());

  void invalid(
    String proof,
    String message, {
    String method = 'GET',
    String? accessToken,
    String? nonce,
    String? thumbprint,
    Duration window = const Duration(seconds: 60),
  }) {
    expect(
      () => verifyDpopProof(
        proof,
        method: method,
        uri: uri,
        accessToken: accessToken,
        nonce: nonce,
        thumbprint: thumbprint,
        window: window,
        now: t0,
      ),
      throwsA(
        isA<DpopProofInvalid>()
            .having((e) => e.message, 'message', message)
            .having(
              (e) => e.toString(),
              'toString',
              'DpopProofInvalid: $message',
            ),
      ),
    );
  }

  group('a proof that is right', () {
    test("is accepted: RFC 9449's own proof, with its key's thumbprint", () {
      final decoded = verifyDpopProof(
        rfcProof,
        method: 'GET',
        uri: rfcUri,
        accessToken: rfcToken,
        now: rfcNow,
        thumbprint: '0ZcOCORZNYy-DWpqq30jZyJGHTN0d2HglBV3uiguA4I',
      );
      expect(decoded.claims['jti'], 'e1j3V_bKic8-LAEB');
      expect(decoded.header['typ'], 'dpop+jwt');
      expect(decoded.jwk['x'], 'l8tFrhx-34tV3hRICRDY9zCkDlpBhF42UQUfWVAWBFs');
    });

    test('is accepted with a query on the request (htu has none)', () async {
      verifyDpopProof(
        await proof(claims_: claims(ath: accessTokenHash(token))),
        method: 'GET',
        uri: uri,
        accessToken: token,
        now: t0,
      );
    });

    test(
      'is accepted inside the window, in both directions, and at its edge',
      () async {
        for (final skew in [-60, -1, 0, 1, 60]) {
          verifyDpopProof(
            await proof(
              claims_: claims(iat: t0.millisecondsSinceEpoch ~/ 1000 + skew),
            ),
            method: 'GET',
            uri: uri,
            now: t0,
          );
        }
      },
    );

    test('carries a nonce nobody asked for', () async {
      verifyDpopProof(
        await proof(claims_: claims(nonce: 'n')),
        method: 'GET',
        uri: uri,
        now: t0,
      );
    });
  });

  group('the first check that fails is the one named', () {
    test('a proof that is not a compact JWS', () {
      for (final bad in ['', 'a.b', 'a.b.c.d', 'a..c']) {
        invalid(bad, 'the proof is not a compact JWS of three parts');
      }
      invalid('!!.@@.##', 'the proof is not made of base64url JSON parts');
      invalid(
        '${b64u(utf8.encode('[]'))}.${b64u(utf8.encode('{}'))}.AAAA',
        'the proof is not made of base64url JSON parts',
      );
    });

    test('typ', () async {
      invalid(
        await proof(
          header: {
            'typ': 'JWT',
            'alg': 'ES256',
            'jwk': await signer.publicJwk(),
          },
        ),
        'typ is JWT, not dpop+jwt',
      );
    });

    test('alg', () async {
      invalid(
        await proof(
          header: {
            'typ': 'dpop+jwt',
            'alg': 'RS256',
            'jwk': await signer.publicJwk(),
          },
        ),
        'alg is RS256, not ES256',
      );
      invalid(
        await proof(
          header: {'typ': 'dpop+jwt', 'jwk': await signer.publicJwk()},
        ),
        'alg is null, not ES256',
      );
    });

    test('the jwk is a public P-256 key on the curve', () async {
      final good = await signer.publicJwk();
      for (final bad in <Object?>[
        null,
        'a string',
        {...good, 'crv': 'P-384'},
        {...good, 'kty': 'OKP'},
        {...good, 'd': 'AAAA'},
        {'kty': 'EC', 'crv': 'P-256', 'x': good['x']},
        {...good, 'x': 7},
        {...good, 'x': 'AAAA'},
        {...good, 'x': '!!!!'},
        // The right size, but not a point of the curve.
        {...good, 'y': good['x']},
      ]) {
        invalid(
          await proof(header: {'typ': 'dpop+jwt', 'alg': 'ES256', 'jwk': bad}),
          'the jwk is not a public P-256 key',
        );
      }
    });

    test('the signature', () async {
      final good = await proof();
      final parts = good.split('.');
      // Another payload under the same signature.
      final other = b64u(utf8.encode(jsonEncode(claims(htm: 'POST'))));
      invalid(
        '${parts[0]}.$other.${parts[2]}',
        'the signature does not verify',
      );
      // A signature of another key.
      final stranger = FakeDpopSigner(seed: 'someone else');
      final signed = await signedProof(
        stranger,
        header: {
          'typ': 'dpop+jwt',
          'alg': 'ES256',
          'jwk': await signer.publicJwk(),
        },
        claims: claims(),
      );
      invalid(signed, 'the signature does not verify');
      // A signature of the wrong size.
      invalid(
        '${parts[0]}.${parts[1]}.${b64u([1, 2, 3])}',
        'the signature does not verify',
      );
    });

    test('htm', () async {
      invalid(await proof(), 'htm is GET, not POST', method: 'POST');
    });

    test('htu', () async {
      invalid(
        await proof(claims_: claims(htu: 'https://evil.example.com/orders')),
        'htu is https://evil.example.com/orders, not https://api.example.com/orders',
      );
      invalid(
        await proof(
          claims_: claims(htu: 'https://api.example.com/orders?page=2'),
        ),
        'htu is https://api.example.com/orders?page=2, not https://api.example.com/orders',
      );
    });

    test('jti', () async {
      invalid(await proof(claims_: claims(jti: null)), 'jti is missing');
      invalid(await proof(claims_: claims(jti: '')), 'jti is missing');
    });

    test('ath', () async {
      invalid(await proof(), 'ath is missing', accessToken: token);
      invalid(
        await proof(claims_: claims(ath: accessTokenHash('another-token'))),
        'ath does not match the access token',
        accessToken: token,
      );
      invalid(
        await proof(claims_: claims(ath: accessTokenHash(token))),
        'ath is set on a request without an access token',
      );
    });

    test('nonce', () async {
      invalid(await proof(), 'nonce is null, not n1', nonce: 'n1');
      invalid(
        await proof(claims_: claims(nonce: 'n0')),
        'nonce is n0, not n1',
        nonce: 'n1',
      );
    });

    test('iat', () async {
      invalid(
        await proof(
          claims_: claims(iat: t0.millisecondsSinceEpoch ~/ 1000 + 120),
        ),
        'iat is 120 s from now',
      );
      invalid(
        await proof(
          claims_: claims(iat: t0.millisecondsSinceEpoch ~/ 1000 - 61),
        ),
        'iat is -61 s from now',
      );
      invalid(
        await proof(
          claims_: claims(iat: t0.millisecondsSinceEpoch ~/ 1000 + 10),
        ),
        'iat is 10 s from now',
        window: const Duration(seconds: 5),
      );
      invalid(await proof(claims_: claims(iat: 'now')), 'iat is missing');
    });

    test("the key's thumbprint", () async {
      invalid(
        await proof(),
        "the key's thumbprint is $fakeThumbprint0, not $fakeThumbprint1",
        thumbprint: fakeThumbprint1,
      );
    });
  });

  test('the checks run in the order they are listed', () async {
    // Wrong in every way at once: the signature is checked before htm and htu.
    final stranger = FakeDpopSigner(seed: 'someone else');
    final bad = await signedProof(
      stranger,
      header: {
        'typ': 'dpop+jwt',
        'alg': 'ES256',
        'jwk': await signer.publicJwk(),
      },
      claims: claims(htm: 'POST', htu: 'https://evil.example.com/'),
    );
    invalid(bad, 'the signature does not verify');
  });
}
