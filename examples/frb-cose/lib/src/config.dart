import 'dart:convert';
import 'dart:typed_data';

import 'core.dart';

/// The server this build talks to, and the key that answers for it: pinned in the build, never learned from the
/// network. The names are this example's own (`--dart-define`).
final class ServerPin {
  /// A server at [baseUrl] that binds [audience] into every message and seals every answer with the P-256 point
  /// (`serverX`, `serverY`, 32 bytes each).
  const ServerPin({
    required this.baseUrl,
    required this.audience,
    required this.serverX,
    required this.serverY,
  });

  /// From the build's defines: `FRB_COSE_SERVER_URL` (default `http://127.0.0.1:8787`), `FRB_COSE_AUDIENCE` (default
  /// `fespalier-frb-cose`) and `FRB_COSE_SERVER_JWK`, the server's public key (the JWK the server prints, or its
  /// whole hello line). Without the key it throws, naming the define.
  factory ServerPin.fromEnvironment() {
    const jwk = String.fromEnvironment('FRB_COSE_SERVER_JWK');
    if (jwk.isEmpty) {
      throw StateError(
        'Pin the server key: start the server (frb-cose-demo-server --listen 127.0.0.1:8787) and build with '
        "--dart-define=FRB_COSE_SERVER_JWK='<its server_public_jwk>'.",
      );
    }
    return ServerPin.fromJwk(
      baseUrl: const String.fromEnvironment(
        'FRB_COSE_SERVER_URL',
        defaultValue: 'http://127.0.0.1:8787',
      ),
      audience: const String.fromEnvironment(
        'FRB_COSE_AUDIENCE',
        defaultValue: 'fespalier-frb-cose',
      ),
      jwk: jwk,
    );
  }

  /// From the server's public key as the JSON text of a JWK.
  ///
  /// The server prints one hello line on startup, `{"addr":…,"audience":…,"server_public_jwk":{…}}`, and that whole
  /// line is what a reader naturally copies. Both are accepted: a hello line is unwrapped to its
  /// `server_public_jwk`, and a bare JWK is taken as itself. Anything else is refused here, naming what it found.
  factory ServerPin.fromJwk({
    required String baseUrl,
    required String audience,
    required String jwk,
  }) {
    final decoded = jsonDecode(jwk);
    if (decoded is! Map<String, Object?>) {
      throw StateError(
        'FRB_COSE_SERVER_JWK must be a JSON object, either the JWK itself or the whole hello line the server prints; '
        'it decoded to a ${decoded.runtimeType}.',
      );
    }
    final inner = decoded['server_public_jwk'];
    final key = inner ?? decoded;
    if (key is! Map<String, Object?>) {
      throw StateError(
        'FRB_COSE_SERVER_JWK has a "server_public_jwk" that is not an object (it is a ${key.runtimeType}).',
      );
    }
    if (key['kty'] != 'EC' || key['crv'] != 'P-256') {
      throw StateError(
        'FRB_COSE_SERVER_JWK is neither a P-256 JWK nor a hello line: it has kty ${key['kty']} and crv '
        '${key['crv']}, and its keys are ${key.keys.toList()..sort()}.',
      );
    }
    return ServerPin(
      baseUrl: baseUrl,
      audience: audience,
      serverX: p256Coordinate('x', key['x']),
      serverY: p256Coordinate('y', key['y']),
    );
  }

  /// The server's origin; the core appends the op's path.
  final String baseUrl;

  /// The id the server binds into every message.
  final String audience;

  /// The server's response key, x (32 bytes).
  final Uint8List serverX;

  /// The server's response key, y (32 bytes).
  final Uint8List serverY;

  /// The core's configuration for a device whose public point is [deviceX], [deviceY].
  CoreConfig configFor({
    required Uint8List deviceX,
    required Uint8List deviceY,
  }) => CoreConfig(
    baseUrl: baseUrl,
    audience: audience,
    deviceX: deviceX,
    deviceY: deviceY,
    serverX: serverX,
    serverY: serverY,
  );
}

/// One coordinate of a P-256 point, from a JWK's base64url text: 32 bytes, or a `StateError` naming [name].
Uint8List p256Coordinate(String name, Object? text) {
  if (text is! String) {
    throw StateError('the JWK has no "$name" coordinate.');
  }
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(base64Url.normalize(text));
  } on FormatException {
    throw StateError('the JWK "$name" coordinate is not base64url.');
  }
  if (bytes.length != 32) {
    throw StateError(
      'the JWK "$name" coordinate is ${bytes.length} bytes, not 32.',
    );
  }
  return bytes;
}
