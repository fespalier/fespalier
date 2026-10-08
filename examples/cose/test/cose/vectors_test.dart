// cratestack-cose's shared vectors (test_vectors/, MIT, see NOTICE) are the oracle: the Dart
// sealer must write the very bytes cratestack's Rust sealer wrote, and the opener must accept and
// refuse what cratestack's verifier accepts and refuses.
import 'dart:typed_data';

import 'package:cose_example/src/cose/cose.dart';
import 'package:flutter_sign_keypair/flutter_sign_keypair.dart'
    show SoftwareSecureSigner;
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

typedef Json = Map<String, Object?>;

void main() {
  final unary = loadVectors('unary.json');
  final keys = loadVectors('keys.json');
  final cases = (unary['cases']! as List<Object?>).cast<Json>();
  final negatives = (unary['negative']! as List<Object?>).cast<Json>();

  Json byName(String name) => cases.firstWhere((c) => c['name'] == name);

  test('the vectors are the ones this test was written against', () {
    expect(cases, hasLength(33));
    expect(negatives, hasLength(22));
  });

  group('encoding, byte for byte (every positive vector)', () {
    for (final c in cases) {
      final name = c['name']! as String;
      final alg = c['alg_id']! as int;
      final bind = bindingOf(c['binding']! as Json);
      final key = keys[c['key']]! as Json;
      final kid = unhex(key['kid']! as String);
      final isRequest = c['direction'] == 'request';

      test('$name: external AAD', () {
        expect(hex(externalAad(bind)), c['external_aad']);
      });

      test('$name: protected header', () {
        final protected = encodeProtected(
          alg,
          kid,
          claims: isRequest
              ? (iat: c['iat']! as int, cti: unhex(c['cti']! as String))
              : null,
        );
        expect(hex(protected), c['protected']);
      });

      // COSE_Mac0 (HMAC) vectors have a MAC_structure and tag 17: not a Sign1.
      if (alg > 0) continue;

      test('$name: Sig_structure', () {
        final tbs = sigStructure(
          protected: unhex(c['protected']! as String),
          externalAad: unhex(c['external_aad']! as String),
          payload: unhex(c['payload']! as String),
        );
        expect(hex(tbs), c['to_be_signed']);
      });

      test('$name: wire layout', () {
        final message = sign1Message(
          protected: unhex(c['protected']! as String),
          payload: unhex(c['payload']! as String),
          // The signature is the last bstr of the vector's own bytes.
          signature: _signatureOf(unhex(c['cose']! as String)),
        );
        expect(hex(message), c['cose']);
      });
    }

    test('a response links to the SHA-256 of the exact request bytes', () {
      var linked = 0;
      for (final c in cases.where((c) => c['request_digest_of'] != null)) {
        final request = byName(c['request_digest_of']! as String);
        final binding = c['binding']! as Json;
        expect(
          hex(requestDigestOf(unhex(request['cose']! as String))),
          binding['request_digest'],
          reason: c['name']! as String,
        );
        expect(binding['request_kind'], 1);
        linked++;
      }
      expect(linked, greaterThan(0));
    });
  });

  group('ESP256 sealing with the vectors\' P-256 key', () {
    late CoseSealer sealer;
    final scalar = unhex((keys['p256']! as Json)['scalar']! as String);

    setUp(() async {
      final software = SoftwareSecureSigner();
      await software.importKey(keyId: 'vectors', privateScalar: scalar);
      sealer = CoseSealer(
        SoftwareDpopSigner(keyId: 'vectors', signer: software),
      );
    });

    final esp = cases.where((c) => c['alg_id'] == -9).toList();

    test('there are 8 ESP256 vectors', () => expect(esp, hasLength(8)));

    for (final c in esp) {
      final name = c['name']! as String;
      test('$name: sealed bytes are the vector, byte for byte', () async {
        final bind = bindingOf(c['binding']! as Json);
        final payload = unhex(c['payload']! as String);
        final sealed = c['direction'] == 'request'
            ? await sealer.sealRequest(
                payload,
                bind,
                iat: c['iat']! as int,
                cti: unhex(c['cti']! as String),
              )
            : await sealer.sealResponse(payload, bind);
        expect(hex(sealed), c['cose']);
      });
    }

    test('the key identifies itself as keys.json says', () async {
      final me = await sealer.identity();
      final p256 = keys['p256']! as Json;
      expect(hex(me.thumbprint), p256['thumbprint']);
      expect(hex(me.kid), p256['kid']);
    });
  });

  group('opening every positive vector', () {
    var skipped = 0;
    for (final c in cases) {
      final name = c['name']! as String;
      final key = verifyKeyNamed(c['key']! as String, keys);
      if (key == null) {
        skipped++;
        test('$name: HMAC (COSE_Mac0) is out of scope for a Sign1 opener', () {
          expect((c['alg_id']! as int) > 0, isTrue);
        });
        continue;
      }
      test('$name: opens with only its key', () {
        final isRequest = c['direction'] == 'request';
        final opener = CoseOpener(
          [key],
          nowSeconds: () => c['verifier_now'] as int? ?? 0,
          skewSeconds: c['skew_secs'] as int? ?? defaultSkewSeconds,
        );
        final bind = bindingOf(c['binding']! as Json);
        final got = isRequest
            ? opener.openRequest(unhex(c['cose']! as String), bind)
            : opener.openResponse(unhex(c['cose']! as String), bind);
        expect(hex(got.payload), c['payload']);
        expect(got.alg, c['alg_id']);
        expect(hex(got.kid), hex(key.kid));
        if (isRequest) {
          expect(got.iat, c['iat']);
          expect(hex(got.cti!), c['cti']);
        }
      });
    }

    test('17 Sign1 vectors open; the 16 HMAC ones are not this library\'s', () {
      expect(cases.length - skipped, 17);
      expect(skipped, 16);
    });
  });

  group('refusing every must-reject vector', () {
    // What makes each refusal a refusal for its stated reason and not for an accident: the same
    // bytes, repaired in exactly that one respect, open.
    final repairs = <String, void Function(Json n, CoseOpener o)>{
      'neg-trailing-byte': (n, o) {
        final cose = unhex(n['cose']! as String);
        o.openRequest(
          Uint8List.sublistView(cose, 0, cose.length - 1),
          bindingOf(n['binding']! as Json),
        );
      },
      'neg-tampered-payload': (n, o) =>
          o.openRequest(_flipPayloadTail(n), bindingOf(n['binding']! as Json)),
      'neg-wrong-audience': (n, o) {
        final b = n['binding']! as Json;
        o.openRequest(
          unhex(n['cose']! as String),
          bindingOf({...b, 'audience': 'payments'}),
        );
      },
      'neg-aad-route-mismatch': (n, o) {
        final b = n['binding']! as Json;
        o.openRequest(
          unhex(n['cose']! as String),
          bindingOf({...b, 'route': 'model.Payment.create'}),
        );
      },
      'neg-contract-sha': (n, o) {
        final b = n['binding']! as Json;
        // The request was sealed for a digest one bit away from the verifier's.
        final sha = unhex(b['contract_sha']! as String);
        sha[31] ^= 0x01;
        o.openRequest(
          unhex(n['cose']! as String),
          bindingOf({...b, 'contract_sha': hex(sha)}),
        );
      },
      'neg-stale-iat': (n, o) {
        final fresh = CoseOpener([
          verifyKeyNamed('ed25519', keys)!,
        ], nowSeconds: () => 1790000000);
        fresh.openRequest(
          unhex(n['cose']! as String),
          bindingOf(n['binding']! as Json),
        );
      },
      'neg-request-digest-mismatch': (n, o) {
        final good = byName('rpc-response-sign1-ed25519')['binding']! as Json;
        o.openResponse(unhex(n['cose']! as String), bindingOf(good));
      },
    };

    for (final n in negatives) {
      final name = n['name']! as String;
      final binding = bindingOf(n['binding']! as Json);
      final heldNames = (n['verifier_keys']! as List<Object?>).cast<String>();
      final held = [
        for (final k in heldNames) verifyKeyNamed(k, keys),
      ].whereType<CoseVerifyKey>().toList();
      final expected500 = (n['expected']! as String).startsWith('reject: 500');

      if (n['mode'] != 'sign1' || held.length != heldNames.length) {
        test('$name: COSE_Mac0 verifier, not this library\'s', () {
          expect(n['mode'], 'mac0');
        });
        continue;
      }

      test('$name: refused (${n['expected']})', () {
        final opener = CoseOpener(
          held,
          nowSeconds: () => n['verifier_now']! as int,
          skewSeconds: n['skew_secs']! as int,
        );
        final cose = unhex(n['cose']! as String);
        final isRequest = n['direction'] == 'request';
        Object? thrown;
        try {
          if (isRequest) {
            opener.openRequest(cose, binding);
          } else {
            opener.openResponse(cose, binding);
          }
        } on Object catch (e) {
          thrown = e;
        }
        expect(
          thrown,
          expected500 ? isA<CoseMisuse>() : isA<CoseRejected>(),
          reason: n['why']! as String,
        );
        if (thrown is CoseRejected) {
          expect(thrown.toString(), contains(CoseRejected.unauthenticated));
        }
      });

      final repair = repairs[name];
      if (repair != null) {
        test('$name: the same bytes open once that one thing is repaired', () {
          final opener = CoseOpener(
            held,
            nowSeconds: () => 1790000000,
            skewSeconds: n['skew_secs']! as int,
          );
          repair(n, opener);
        });
      }
    }

    test(
      'neg-esp256-high-s: the twin is the valid signature with s -> n - s',
      () {
        final n = negatives.firstWhere((n) => n['name'] == 'neg-esp256-high-s');
        final valid = byName('rest-request-sign1-esp256-cti16');
        final high = _signatureOf(unhex(n['cose']! as String));
        final low = _signatureOf(unhex(valid['cose']! as String));
        expect(hex(normalizeLowS(high)), hex(low));
      },
    );
  });
}

/// The vector with the payload's last byte's low bit flipped back (the signature is a 64-byte
/// string with a 2-byte head, so the payload ends 66 bytes before the end).
Uint8List _flipPayloadTail(Json n) {
  final out = Uint8List.fromList(unhex(n['cose']! as String));
  out[out.length - 1 - 66] ^= 0x01;
  return out;
}

Uint8List _signatureOf(Uint8List cose) =>
    Uint8List.sublistView(cose, cose.length - 64);
