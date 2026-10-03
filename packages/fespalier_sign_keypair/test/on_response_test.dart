// What DpopProof does with responses: the nonces it keeps, the challenges it answers once, and
// the clock correction. The error shapes are RFC 9449's (sections 5, 7.1, 8 and 9) and, for the
// clock, the ones read from Keycloak 26.8.0 (invalid_request, "DPoP proof is not active", no Date
// header of its own).
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final tokenUri = Uri.parse('https://sso.example.com/token');
final apiUri = Uri.parse('https://api.example.com/orders');

String error(String code, [String? description]) =>
    jsonEncode({'error': code, 'error_description': ?description});

void main() {
  late DpopProof dpop;
  setUp(
    () => dpop = DpopProof(signer: FakeDpopSigner(), random: CountingRandom()),
  );

  bool respond(
    Uri uri,
    int status, {
    Map<String, String> headers = const {},
    String? body,
    bool retried = false,
  }) => dpop.onResponse(
    uri: uri,
    statusCode: status,
    headers: headers,
    body: body,
    retried: retried,
  );

  Future<Map<String, Object?>> claims(Uri uri) async =>
      part(await dpop.proof(method: 'GET', uri: uri), 1);

  group('nonces', () {
    test(
      'a nonce on any response, a 200 included, is kept for its origin',
      () async {
        expect(respond(apiUri, 200, headers: {'dpop-nonce': 'n-api'}), isFalse);
        expect((await claims(apiUri))['nonce'], 'n-api');
        // Another path of the same origin, and the default port spelled out.
        expect(
          (await claims(Uri.parse('https://api.example.com:443/x')))['nonce'],
          'n-api',
        );
        // Another origin has none: an authorization server and a resource server keep their own.
        expect((await claims(tokenUri)).containsKey('nonce'), isFalse);
        expect(
          (await claims(
            Uri.parse('http://api.example.com/orders'),
          )).containsKey('nonce'),
          isFalse,
        );
        expect(
          (await claims(
            Uri.parse('https://api.example.com:8443/orders'),
          )).containsKey('nonce'),
          isFalse,
        );
      },
    );

    test('a newer nonce replaces the older one', () async {
      respond(apiUri, 200, headers: {'dpop-nonce': 'one'});
      respond(apiUri, 200, headers: {'dpop-nonce': 'two'});
      expect((await claims(apiUri))['nonce'], 'two');
    });

    test('an empty nonce is not kept', () async {
      respond(apiUri, 200, headers: {'dpop-nonce': ''});
      expect((await claims(apiUri)).containsKey('nonce'), isFalse);
    });

    test(
      'an authorization server challenge (400, use_dpop_nonce, DPoP-Nonce) is answered once',
      () async {
        expect(
          respond(
            tokenUri,
            400,
            headers: {'dpop-nonce': 'eyJ7S_zG.eyJH0-Z.HX4w-7v'},
            body: error(
              'use_dpop_nonce',
              'Authorization server requires nonce in DPoP proof',
            ),
          ),
          isTrue,
        );
        expect((await claims(tokenUri))['nonce'], 'eyJ7S_zG.eyJH0-Z.HX4w-7v');
        // The retry is refused again: not a second time.
        expect(
          respond(
            tokenUri,
            400,
            headers: {'dpop-nonce': 'another'},
            body: error('use_dpop_nonce'),
            retried: true,
          ),
          isFalse,
        );
        // ... but the new nonce is kept for the next request.
        expect((await claims(tokenUri))['nonce'], 'another');
      },
    );

    test('a challenge with no nonce to use is not retried', () {
      expect(respond(tokenUri, 400, body: error('use_dpop_nonce')), isFalse);
    });

    test(
      'a resource server challenge (401, WWW-Authenticate: DPoP error="use_dpop_nonce") is answered once',
      () async {
        const challenge =
            'DPoP error="use_dpop_nonce", error_description="Resource server requires nonce in DPoP proof"';
        expect(
          respond(
            apiUri,
            401,
            headers: {'www-authenticate': challenge, 'dpop-nonce': 'rs-nonce'},
          ),
          isTrue,
        );
        expect((await claims(apiUri))['nonce'], 'rs-nonce');
        expect(
          respond(
            apiUri,
            401,
            headers: {'www-authenticate': challenge, 'dpop-nonce': 'rs-2'},
            retried: true,
          ),
          isFalse,
        );
      },
    );

    test(
      'the DPoP challenge is found among others, and a Bearer one is not mistaken for it',
      () {
        expect(
          respond(
            apiUri,
            401,
            headers: {
              'www-authenticate':
                  'Bearer realm="api", DPoP algs="ES256 PS256", error="use_dpop_nonce"',
              'dpop-nonce': 'n',
            },
          ),
          isTrue,
        );
        expect(
          respond(
            apiUri,
            401,
            headers: {
              'www-authenticate':
                  'DPoP algs="ES256", Bearer realm="api", error="use_dpop_nonce"',
              'dpop-nonce': 'n',
            },
          ),
          isFalse,
          reason: 'the error belongs to the Bearer challenge',
        );
        expect(
          respond(
            apiUri,
            401,
            headers: {
              'www-authenticate': 'Bearer realm="api", error="use_dpop_nonce"',
              'dpop-nonce': 'n',
            },
          ),
          isFalse,
        );
      },
    );

    test('other responses are not challenges', () {
      expect(respond(apiUri, 200), isFalse);
      expect(respond(apiUri, 403, headers: {'dpop-nonce': 'n'}), isFalse);
      expect(
        respond(
          tokenUri,
          500,
          body: error('use_dpop_nonce'),
          headers: {'dpop-nonce': 'n'},
        ),
        isFalse,
      );
      expect(respond(tokenUri, 400, body: 'not json'), isFalse);
      expect(respond(tokenUri, 400, body: '[]'), isFalse);
      expect(respond(tokenUri, 400, body: jsonEncode({'error': 1})), isFalse);
      expect(respond(apiUri, 401), isFalse);
      expect(
        respond(apiUri, 401, headers: {'www-authenticate': 'Bearer realm="x"'}),
        isFalse,
      );
    });
  });

  group('the clock', () {
    final ahead = httpDate(t0.add(const Duration(minutes: 2)));

    test(
      'an invalid_dpop_proof with a Date far from the clock is corrected, once',
      () async {
        await withClock(Clock.fixed(t0), () async {
          expect(
            respond(
              tokenUri,
              400,
              headers: {'date': ahead},
              body: error('invalid_dpop_proof', 'DPoP proof is not active'),
            ),
            isTrue,
          );
          expect(dpop.clockOffset, const Duration(minutes: 2));
          expect(
            (await claims(tokenUri))['iat'],
            t0.millisecondsSinceEpoch ~/ 1000 + 120,
          );
          // The same Date again: already corrected, so not again.
          expect(
            respond(
              tokenUri,
              400,
              headers: {'date': ahead},
              body: error('invalid_dpop_proof'),
            ),
            isFalse,
          );
          expect(dpop.clockOffset, const Duration(minutes: 2));
        });
      },
    );

    test(
      'Keycloak says invalid_request and "DPoP proof is not active"',
      () async {
        await withClock(Clock.fixed(t0), () async {
          expect(
            respond(
              tokenUri,
              400,
              headers: {
                'date': httpDate(t0.subtract(const Duration(seconds: 90))),
              },
              body: error('invalid_request', 'DPoP proof is not active'),
            ),
            isTrue,
          );
          expect(dpop.clockOffset, const Duration(seconds: -90));
        });
      },
    );

    test(
      'other invalid_request descriptions are not about the clock',
      () async {
        await withClock(Clock.fixed(t0), () async {
          for (final description in [
            'DPoP proof is missing',
            'DPoP proof has already been used',
            'DPoP Proof public key thumbprint does not match dpop_jkt',
          ]) {
            expect(
              respond(
                tokenUri,
                400,
                headers: {'date': ahead},
                body: error('invalid_request', description),
              ),
              isFalse,
              reason: description,
            );
          }
          expect(dpop.clockOffset, Duration.zero);
        });
      },
    );

    test(
      'a resource server that says invalid_dpop_proof (RFC 9449) or invalid_token (Keycloak) is corrected too',
      () async {
        await withClock(Clock.fixed(t0), () async {
          expect(
            respond(
              apiUri,
              401,
              headers: {
                'www-authenticate':
                    'DPoP error="invalid_dpop_proof", algs="ES256"',
                'date': ahead,
              },
            ),
            isTrue,
          );
          await dpop.reset();
          expect(
            respond(
              apiUri,
              401,
              headers: {
                'www-authenticate':
                    'DPoP algs="PS384 ES256", realm="fespalier", error="invalid_token", error_description="Token verification failed"',
                'date': ahead,
              },
            ),
            isTrue,
          );
          expect(dpop.clockOffset, const Duration(minutes: 2));
        });
      },
    );

    test('a Date near the clock is not a clock problem', () async {
      await withClock(Clock.fixed(t0), () async {
        expect(
          respond(
            tokenUri,
            400,
            headers: {'date': httpDate(t0.add(const Duration(seconds: 4)))},
            body: error('invalid_dpop_proof'),
          ),
          isFalse,
        );
        expect(dpop.clockOffset, Duration.zero);
      });
    });

    test(
      'with no Date, or one that does not parse, nothing is learned (Keycloak sends none)',
      () async {
        await withClock(Clock.fixed(t0), () async {
          expect(
            respond(tokenUri, 400, body: error('invalid_dpop_proof')),
            isFalse,
          );
          expect(
            respond(
              tokenUri,
              400,
              headers: {'date': 'yesterday-ish'},
              body: error('invalid_dpop_proof'),
            ),
            isFalse,
          );
          expect(dpop.clockOffset, Duration.zero);
        });
      },
    );

    test('never when the request was already retried', () async {
      await withClock(Clock.fixed(t0), () async {
        expect(
          respond(
            tokenUri,
            400,
            headers: {'date': ahead},
            body: error('invalid_dpop_proof'),
            retried: true,
          ),
          isFalse,
        );
        expect(dpop.clockOffset, Duration.zero);
      });
    });

    test(
      'is learned from errors only: a 200 with a Date changes nothing',
      () async {
        await withClock(Clock.fixed(t0), () async {
          expect(respond(apiUri, 200, headers: {'date': ahead}), isFalse);
          expect(dpop.clockOffset, Duration.zero);
        });
      },
    );

    test(
      'a wrong correction is replaced by a better one, never by the same',
      () async {
        await withClock(Clock.fixed(t0), () async {
          respond(
            tokenUri,
            400,
            headers: {'date': ahead},
            body: error('invalid_dpop_proof'),
          );
          expect(dpop.clockOffset, const Duration(minutes: 2));
          final later = httpDate(t0.add(const Duration(minutes: 10)));
          expect(
            respond(
              tokenUri,
              400,
              headers: {'date': later},
              body: error('invalid_dpop_proof'),
            ),
            isTrue,
          );
          expect(dpop.clockOffset, const Duration(minutes: 10));
        });
      },
    );

    test('a threshold of your own', () async {
      final strict = DpopProof(
        signer: FakeDpopSigner(),
        clockCorrectionThreshold: const Duration(seconds: 1),
      );
      await withClock(Clock.fixed(t0), () async {
        expect(
          strict.onResponse(
            uri: tokenUri,
            statusCode: 400,
            headers: {'date': httpDate(t0.add(const Duration(seconds: 3)))},
            body: error('invalid_dpop_proof'),
            retried: false,
          ),
          isTrue,
        );
        expect(strict.clockOffset, const Duration(seconds: 3));
      });
    });
  });
}
