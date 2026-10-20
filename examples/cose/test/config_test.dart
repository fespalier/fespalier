import 'dart:convert';

import 'package:cose_example/src/cose_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real P-256 coordinate, so a JWK that carries one is a usable key.
const String _x = 'E8LKhUtw1gs762xvmGhaHruBfljGLN4bg4HLvJM7Q20';
const String _y = 'T8bXmosAVJTNYMcoN2nNsbSmkJzJWvbJODPuKxRD8a4';

final Uri _base = Uri.parse('http://127.0.0.1:8787');

CoseConfig _config(String jwk) =>
    CoseConfig.fromJwk(baseUrl: _base, audience: 'fespalier-cose', jwk: jwk);

void main() {
  group('CoseConfig.fromJwk', () {
    test('takes a bare JWK', () {
      final config = _config(
        jsonEncode({'kty': 'EC', 'crv': 'P-256', 'x': _x, 'y': _y}),
      );
      expect(config.serverKey.kid, hasLength(8));
    });

    test('unwraps the hello line the server prints', () {
      // The line a reader copies from the server's stdout, whole.
      final hello = jsonEncode({
        'addr': '127.0.0.1:8787',
        'audience': 'fespalier-cose',
        'server_public_jwk': {'crv': 'P-256', 'kty': 'EC', 'x': _x, 'y': _y},
      });

      final fromHello = _config(hello);
      final fromJwk = _config(
        jsonEncode({'kty': 'EC', 'crv': 'P-256', 'x': _x, 'y': _y}),
      );

      // The same key, not merely a key that parsed.
      expect(fromHello.serverKey.kid, fromJwk.serverKey.kid);
    });

    test('refuses a hello line whose key is not an object', () {
      final hello = jsonEncode({
        'addr': '127.0.0.1:8787',
        'server_public_jwk': 'nonsense',
      });
      expect(() => _config(hello), throwsA(isA<StateError>()));
    });

    test('refuses an object that holds no key, naming the mistake', () {
      // e.g. the URL define pasted by accident: valid JSON, no key anywhere.
      final notAKey = jsonEncode({'url': 'http://127.0.0.1:8787'});
      expect(
        () => _config(notAKey),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('COSE_SERVER_JWK'), contains('server_public_jwk')),
          ),
        ),
      );
    });

    test('refuses a JSON value that is not an object', () {
      expect(() => _config('"just a string"'), throwsA(isA<StateError>()));
    });
  });
}
