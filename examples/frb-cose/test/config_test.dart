import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frb_cose_example/src/config.dart';

/// A real P-256 point, so a JWK that carries one is a usable key (the public test key of config tests elsewhere).
const String _x = 'E8LKhUtw1gs762xvmGhaHruBfljGLN4bg4HLvJM7Q20';
const String _y = 'T8bXmosAVJTNYMcoN2nNsbSmkJzJWvbJODPuKxRD8a4';

const String _base = 'http://127.0.0.1:8787';

ServerPin _pin(String jwk) =>
    ServerPin.fromJwk(baseUrl: _base, audience: 'fespalier-frb-cose', jwk: jwk);

String _jwk() => jsonEncode({'kty': 'EC', 'crv': 'P-256', 'x': _x, 'y': _y});

void main() {
  group('ServerPin.fromJwk', () {
    test('takes a bare JWK, as 32-byte coordinates', () {
      final pin = _pin(_jwk());

      expect(pin.serverX, hasLength(32));
      expect(pin.serverY, hasLength(32));
      expect(pin.baseUrl, _base);
      expect(pin.audience, 'fespalier-frb-cose');
    });

    test('unwraps the hello line the server prints', () {
      // The line a reader copies from the server's stdout, whole.
      final hello = jsonEncode({
        'addr': '127.0.0.1:8787',
        'audience': 'fespalier-frb-cose',
        'server_public_jwk': {'crv': 'P-256', 'kty': 'EC', 'x': _x, 'y': _y},
      });

      final fromHello = _pin(hello);
      final fromJwk = _pin(_jwk());

      expect(fromHello.serverX, fromJwk.serverX, reason: 'the same key');
      expect(fromHello.serverY, fromJwk.serverY);
    });

    test('refuses a hello line whose key is not an object', () {
      final hello = jsonEncode({
        'addr': '127.0.0.1:8787',
        'server_public_jwk': 'nonsense',
      });
      expect(() => _pin(hello), throwsA(isA<StateError>()));
    });

    test('refuses an object that holds no key, naming the mistake', () {
      // The URL define pasted by accident: valid JSON, no key anywhere.
      final notAKey = jsonEncode({'url': _base});
      expect(
        () => _pin(notAKey),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('FRB_COSE_SERVER_JWK'), contains('kty')),
          ),
        ),
      );
    });

    test('refuses a key that is not P-256', () {
      final ed = jsonEncode({'kty': 'OKP', 'crv': 'Ed25519', 'x': _x});
      expect(
        () => _pin(ed),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('P-256'),
          ),
        ),
      );
    });

    test('refuses a coordinate that is not 32 bytes', () {
      final short = jsonEncode({
        'kty': 'EC',
        'crv': 'P-256',
        'x': 'AAAA',
        'y': _y,
      });
      expect(
        () => _pin(short),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not 32'),
          ),
        ),
      );
    });

    test('refuses a coordinate that is not base64url, or is missing', () {
      final bad = jsonEncode({
        'kty': 'EC',
        'crv': 'P-256',
        'x': 'not base64!',
        'y': _y,
      });
      expect(
        () => _pin(bad),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not base64url'),
          ),
        ),
      );
      final missing = jsonEncode({'kty': 'EC', 'crv': 'P-256', 'x': _x});
      expect(
        () => _pin(missing),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no "y" coordinate'),
          ),
        ),
      );
    });

    test('refuses a define that is not a JSON object', () {
      expect(() => _pin('[1, 2]'), throwsA(isA<StateError>()));
    });
  });

  test('the core config carries the server and the device point', () {
    final pin = _pin(_jwk());
    final deviceX = Uint8List.fromList(List.filled(32, 7));
    final deviceY = Uint8List.fromList(List.filled(32, 9));

    final config = pin.configFor(deviceX: deviceX, deviceY: deviceY);

    expect(config.baseUrl, _base);
    expect(config.audience, 'fespalier-frb-cose');
    expect(config.deviceX, deviceX);
    expect(config.deviceY, deviceY);
    expect(config.serverX, pin.serverX);
    expect(config.serverY, pin.serverY);
  });

  test(
    'without a key the define is named, not guessed',
    () {
      expect(
        () => ServerPin.fromEnvironment(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('FRB_COSE_SERVER_JWK'),
          ),
        ),
      );
    },
    skip: const String.fromEnvironment('FRB_COSE_SERVER_JWK').isNotEmpty
        ? 'the build defines FRB_COSE_SERVER_JWK'
        : false,
  );
}
