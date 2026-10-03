import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// Made with python-cryptography (RFC 6979 deterministic signing) and hashlib, not with Dart:
/// the FakeDpopSigner's first key, jti = the bytes 0..15, iat = 2026-10-03T12:00:00Z. See
/// thumbprint_test.dart for the key.
const goldenTokenRequest =
    'eyJ0eXAiOiJkcG9wK2p3dCIsImFsZyI6IkVTMjU2IiwiandrIjp7ImNydiI6IlAtMjU2Iiwia3R5IjoiRUMiLCJ4IjoiV05Fd0pDRlVkWnBUVTFSYjVFZWMxSTdkSDNiY2ZrNDVqczV4Z3lPX2dzSSIsInkiOiJCemhaUEFTZFpHXzZ6a2hIZHRGZ0pQbFFheTR5RW1BeGYyQ3BrTkE0N3A0In19.eyJqdGkiOiJBQUVDQXdRRkJnY0lDUW9MREEwT0R3IiwiaHRtIjoiUE9TVCIsImh0dSI6Imh0dHBzOi8vc3NvLmV4YW1wbGUuY29tL3JlYWxtcy9zaG9wL3Byb3RvY29sL29wZW5pZC1jb25uZWN0L3Rva2VuIiwiaWF0IjoxNzkxMDI4ODAwfQ.b__HXzqZ2UftTLgsCDPXrnJNavcD8IIn1URd7ny3uvhMWyK0pOYN1OtEQq8nkoCa690ELEgYSbzVJBXCsPbRLg';
const goldenApiRequest =
    'eyJ0eXAiOiJkcG9wK2p3dCIsImFsZyI6IkVTMjU2IiwiandrIjp7ImNydiI6IlAtMjU2Iiwia3R5IjoiRUMiLCJ4IjoiV05Fd0pDRlVkWnBUVTFSYjVFZWMxSTdkSDNiY2ZrNDVqczV4Z3lPX2dzSSIsInkiOiJCemhaUEFTZFpHXzZ6a2hIZHRGZ0pQbFFheTR5RW1BeGYyQ3BrTkE0N3A0In19.eyJqdGkiOiJBQUVDQXdRRkJnY0lDUW9MREEwT0R3IiwiaHRtIjoiR0VUIiwiaHR1IjoiaHR0cHM6Ly9hcGkuZXhhbXBsZS5jb20vb3JkZXJzIiwiaWF0IjoxNzkxMDI4ODAwLCJhdGgiOiJmVUh5TzJyMlozRFo1M0VzTnJXQmIweFdYb2FOeTU5SWlLQ0Fxa3NtUUVvIiwibm9uY2UiOiJzZXJ2ZXItbm9uY2UtMSJ9.Z4L9C4jwLmRQuCcgAL_5DySgUS5sM-YnPsgLQTfvxHqSEpcb0ouI9xxLrBIk9u4C_11r6CoGmkmJ_X4zhObtrw';

const accessToken = 'Kz~8mXK1EalYznwH-LC-1fBAo.4Ljp~zsPE_NeO.gxU';
final tokenUri = Uri.parse(
  'https://sso.example.com/realms/shop/protocol/openid-connect/token',
);
final apiUri = Uri.parse('https://api.example.com/orders');

DpopProof newProof({
  FakeDpopSigner? signer,
  bool rotate = true,
  bool counting = true,
}) => DpopProof(
  signer: signer ?? FakeDpopSigner(),
  rotateKeyOnSignOut: rotate,
  random: counting ? CountingRandom() : null,
);

void main() {
  group('the proof', () {
    test('is exactly what python made for a token request (golden)', () async {
      final dpop = newProof();
      final proof = await withClock(
        Clock.fixed(t0),
        () => dpop.proof(method: 'POST', uri: tokenUri),
      );
      expect(proof, goldenTokenRequest);
    });

    test(
      'is exactly what python made for an API request with ath and a nonce',
      () async {
        final dpop = newProof();
        dpop.onResponse(
          uri: apiUri,
          statusCode: 200,
          headers: {'dpop-nonce': 'server-nonce-1'},
          retried: false,
        );
        final proof = await withClock(
          Clock.fixed(t0),
          () =>
              dpop.proof(method: 'GET', uri: apiUri, accessToken: accessToken),
        );
        expect(proof, goldenApiRequest);
      },
    );

    test(
      'has the header and the claims of RFC 9449 section 4.2, in order',
      () async {
        final dpop = newProof();
        final proof = await withClock(
          Clock.fixed(t0),
          () => dpop.proof(method: 'POST', uri: Uri.parse('$tokenUri?a=b#c')),
        );
        final header = part(proof, 0);
        final claims = part(proof, 1);
        expect(header.keys, ['typ', 'alg', 'jwk']);
        expect(header['typ'], 'dpop+jwt');
        expect(header['alg'], 'ES256');
        expect(header['jwk'], fakeJwk0);
        expect((header['jwk']! as Map).keys, ['crv', 'kty', 'x', 'y']);
        expect(claims.keys, ['jti', 'htm', 'htu', 'iat']);
        expect(claims['htm'], 'POST');
        expect(claims['htu'], tokenUri.toString());
        expect(claims['iat'], t0.millisecondsSinceEpoch ~/ 1000);
        expect(unb64u(proof.split('.')[2]), hasLength(64));
      },
    );

    test(
      'has no ath without an access token: a token request never carries one',
      () async {
        final dpop = newProof();
        final claims = part(await dpop.proof(method: 'POST', uri: tokenUri), 1);
        expect(claims.containsKey('ath'), isFalse);
        final api = part(
          await dpop.proof(
            method: 'GET',
            uri: apiUri,
            accessToken: accessToken,
          ),
          1,
        );
        expect(api['ath'], accessTokenHash(accessToken));
      },
    );

    test('has a jti of 22 characters, new for every proof', () async {
      final dpop = DpopProof(signer: FakeDpopSigner());
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        final jti =
            part(await dpop.proof(method: 'GET', uri: apiUri), 1)['jti']!
                as String;
        expect(jti, hasLength(22));
        expect(jti, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
        seen.add(jti);
      }
      expect(seen, hasLength(50));
    });

    test('follows the clock', () async {
      final dpop = newProof();
      final first = await withClock(
        Clock.fixed(t0),
        () => dpop.proof(method: 'GET', uri: apiUri),
      );
      final later = await withClock(
        Clock.fixed(t0.add(const Duration(minutes: 6))),
        () => dpop.proof(method: 'GET', uri: apiUri),
      );
      expect(
        part(later, 1)['iat']! as int,
        (part(first, 1)['iat']! as int) + 360,
      );
    });

    test(
      'verifies with verifyDpopProof, for a token request and an API request',
      () async {
        final dpop = newProof(counting: false);
        await withClock(Clock.fixed(t0), () async {
          final token = await dpop.proof(method: 'POST', uri: tokenUri);
          final decoded = verifyDpopProof(
            token,
            method: 'POST',
            uri: tokenUri,
            now: t0,
            thumbprint: fakeThumbprint0,
          );
          expect(decoded.thumbprint, fakeThumbprint0);
          expect(decoded.jwk, fakeJwk0);
          final api = await dpop.proof(
            method: 'GET',
            uri: Uri.parse('https://api.example.com/orders?page=2'),
            accessToken: accessToken,
          );
          verifyDpopProof(
            api,
            method: 'GET',
            uri: Uri.parse('https://api.example.com/orders?page=2'),
            accessToken: accessToken,
            now: t0,
          );
        });
      },
    );

    test(
      'is made by the signer, once per proof, and nothing is kept between proofs',
      () async {
        final signer = FakeDpopSigner();
        final dpop = newProof(signer: signer);
        await dpop.proof(method: 'GET', uri: apiUri);
        await dpop.proof(method: 'GET', uri: apiUri);
        await dpop.headers(
          method: 'GET',
          uri: apiUri,
          accessToken: accessToken,
        );
        expect(signer.signatures, 3);
      },
    );

    test('headers are {DPoP: proof}', () async {
      final dpop = newProof();
      final headers = await dpop.headers(method: 'GET', uri: apiUri);
      expect(headers.keys, ['DPoP']);
      expect(headers['DPoP']!.split('.'), hasLength(3));
    });

    test(
      'a signer that does not return 64 bytes is refused, in words',
      () async {
        final dpop = DpopProof(signer: _ShortSigner());
        await expectLater(
          dpop.proof(method: 'GET', uri: apiUri),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'fespalier_sign_keypair: the signer returned 70 bytes, not the '
                  '64-byte r||s signature that ES256 needs',
            ),
          ),
        );
      },
    );
  });

  group('the thumbprint and the key', () {
    test('thumbprint is the RFC 7638 one of the signer key', () async {
      expect(await newProof().thumbprint(), fakeThumbprint0);
    });

    test('publicJwk is the signer key', () async {
      expect(await newProof().publicJwk(), fakeJwk0);
    });

    test(
      'reset forgets the nonces and the clock correction and deletes the key',
      () async {
        final signer = FakeDpopSigner();
        final dpop = newProof(signer: signer);
        dpop.onResponse(
          uri: apiUri,
          statusCode: 200,
          headers: {'dpop-nonce': 'n1'},
          retried: false,
        );
        expect(
          part(await dpop.proof(method: 'GET', uri: apiUri), 1)['nonce'],
          'n1',
        );
        await dpop.reset();
        expect(signer.deletes, 1);
        expect(dpop.clockOffset, Duration.zero);
        final claims = part(await dpop.proof(method: 'GET', uri: apiUri), 1);
        expect(claims.containsKey('nonce'), isFalse);
        // A new key at the next sign-in: another thumbprint, and the header follows it.
        expect(await dpop.thumbprint(), fakeThumbprint1);
        final proof = await dpop.proof(method: 'GET', uri: apiUri);
        expect(
          verifyDpopProof(proof, method: 'GET', uri: apiUri).thumbprint,
          fakeThumbprint1,
        );
      },
    );

    test('rotateKeyOnSignOut: false keeps the key', () async {
      final signer = FakeDpopSigner();
      final dpop = newProof(signer: signer, rotate: false);
      await dpop.reset();
      expect(signer.deletes, 0);
      expect(await dpop.thumbprint(), fakeThumbprint0);
    });

    test(
      'the header follows a key that was replaced behind its back',
      () async {
        final signer = FakeDpopSigner();
        final dpop = newProof(signer: signer);
        await dpop.proof(method: 'GET', uri: apiUri);
        await signer.deleteKey();
        final proof = await dpop.proof(method: 'GET', uri: apiUri);
        // Verifies: the cached header was not reused for the new key.
        expect(
          verifyDpopProof(proof, method: 'GET', uri: apiUri).thumbprint,
          fakeThumbprint1,
        );
      },
    );
  });
}

/// A signer whose signature is DER-sized, not r||s.
final class _ShortSigner implements DpopSigner {
  final FakeDpopSigner _fake = FakeDpopSigner();

  @override
  Future<Map<String, String>> publicJwk() => _fake.publicJwk();

  @override
  Future<Uint8List> sign(Uint8List signingInput) async => Uint8List(70);

  @override
  Future<bool> isHardwareBacked() async => false;

  @override
  Future<void> deleteKey() async {}
}
