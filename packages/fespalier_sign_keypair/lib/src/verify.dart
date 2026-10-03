import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:pointycastle/export.dart' as pc;

import 'jose.dart';

/// A proof that [verifyDpopProof] refused, and the first check it failed (since 0.9.0).
///
/// `toString` is `DpopProofInvalid: <message>`. The message never carries the proof, a token or
/// a key.
final class DpopProofInvalid implements Exception {
  /// A refusal for [message].
  const DpopProofInvalid(this.message);

  /// The check that failed, in a sentence.
  final String message;

  @override
  String toString() => 'DpopProofInvalid: $message';
}

/// A proof that [verifyDpopProof] accepted: its header and its claims (since 0.9.0).
final class DecodedDpopProof {
  /// A decoded proof.
  const DecodedDpopProof({required this.header, required this.claims});

  /// The JOSE header: `typ`, `alg` and the public `jwk`.
  final Map<String, Object?> header;

  /// The claims: `jti`, `htm`, `htu`, `iat`, and `ath` and `nonce` when they are there.
  final Map<String, Object?> claims;

  /// The proof's public key as `{crv, kty, x, y}`.
  Map<String, String> get jwk {
    final raw = header['jwk']! as Map<String, Object?>;
    return <String, String>{
      'crv': raw['crv']! as String,
      'kty': raw['kty']! as String,
      'x': raw['x']! as String,
      'y': raw['y']! as String,
    };
  }

  /// The RFC 7638 thumbprint of [jwk]: what an authorization server binds tokens to
  /// (`cnf.jkt`).
  String get thumbprint => jwkThumbprint(jwk);
}

/// Checks the DPoP proof [proof] for a request ([method] [uri]) the way a server does, and
/// returns what it says (since 0.9.0). Pure Dart: a demo server and a test check proofs with it.
///
/// The checks, in order: a compact JWS of three parts; `typ` is `dpop+jwt`; `alg` is `ES256`;
/// `jwk` is a public P-256 key on the curve (no `d`); the signature verifies with it; `htm` is
/// [method]; `htu` is `dpopHtu(uri)`; a `jti` is there; `ath` is `accessTokenHash(accessToken)`
/// when [accessToken] is given, and absent otherwise; `nonce` is [nonce] when that is given;
/// `iat` is within [window] of [now] (`clock.now()` by default); and, when [thumbprint] is
/// given, the key's thumbprint is it. Throws a [DpopProofInvalid] naming the first check that
/// failed.
///
/// It does **not** remember `jti`s: refusing a proof that was already used is the server's job
/// (a set of the `jti`s seen inside [window]).
DecodedDpopProof verifyDpopProof(
  String proof, {
  required String method,
  required Uri uri,
  String? accessToken,
  String? nonce,
  String? thumbprint,
  Duration window = const Duration(seconds: 60),
  DateTime? now,
}) {
  final parts = proof.split('.');
  if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
    throw const DpopProofInvalid(
      'the proof is not a compact JWS of three parts',
    );
  }
  final Map<String, Object?> header;
  final Map<String, Object?> claims;
  final Uint8List signature;
  try {
    header = _object(parts[0]);
    claims = _object(parts[1]);
    signature = base64UrlDecodeLoose(parts[2]);
  } on FormatException {
    throw const DpopProofInvalid(
      'the proof is not made of base64url JSON parts',
    );
  }
  if (header['typ'] != 'dpop+jwt') {
    throw DpopProofInvalid('typ is ${header['typ']}, not dpop+jwt');
  }
  if (header['alg'] != 'ES256') {
    throw DpopProofInvalid('alg is ${header['alg']}, not ES256');
  }
  final point = _publicPoint(header['jwk']);
  if (point == null) {
    throw const DpopProofInvalid('the jwk is not a public P-256 key');
  }
  if (!_verifies(point, utf8.encode('${parts[0]}.${parts[1]}'), signature)) {
    throw const DpopProofInvalid('the signature does not verify');
  }
  if (claims['htm'] != method) {
    throw DpopProofInvalid('htm is ${claims['htm']}, not $method');
  }
  final htu = dpopHtu(uri);
  if (claims['htu'] != htu) {
    throw DpopProofInvalid('htu is ${claims['htu']}, not $htu');
  }
  final jti = claims['jti'];
  if (jti is! String || jti.isEmpty) {
    throw const DpopProofInvalid('jti is missing');
  }
  final ath = claims['ath'];
  if (accessToken != null) {
    if (ath == null) throw const DpopProofInvalid('ath is missing');
    if (ath != accessTokenHash(accessToken)) {
      throw const DpopProofInvalid('ath does not match the access token');
    }
  } else if (ath != null) {
    throw const DpopProofInvalid(
      'ath is set on a request without an access token',
    );
  }
  if (nonce != null && claims['nonce'] != nonce) {
    throw DpopProofInvalid('nonce is ${claims['nonce']}, not $nonce');
  }
  final iat = claims['iat'];
  if (iat is! num) throw const DpopProofInvalid('iat is missing');
  final seconds =
      iat.toInt() - (now ?? clock.now()).millisecondsSinceEpoch ~/ 1000;
  if (seconds.abs() > window.inSeconds) {
    throw DpopProofInvalid('iat is $seconds s from now');
  }
  final decoded = DecodedDpopProof(header: header, claims: claims);
  if (thumbprint != null && decoded.thumbprint != thumbprint) {
    throw DpopProofInvalid(
      "the key's thumbprint is ${decoded.thumbprint}, not $thumbprint",
    );
  }
  return decoded;
}

Map<String, Object?> _object(String part) {
  final decoded = jsonDecode(utf8.decode(base64UrlDecodeLoose(part)));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('not a JSON object');
  }
  return decoded;
}

final pc.ECDomainParameters _domain = pc.ECDomainParameters('prime256v1');

// P-256's field prime and b (FIPS 186-4 D.1.2.3); a is -3.
final BigInt _p = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final BigInt _b = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);

/// The point of a public P-256 JWK, or null when it is anything else (another curve, a private
/// key, coordinates of the wrong size, a point off the curve).
pc.ECPoint? _publicPoint(Object? jwk) {
  if (jwk is! Map<String, Object?>) return null;
  if (jwk['kty'] != 'EC' || jwk['crv'] != 'P-256' || jwk.containsKey('d')) {
    return null;
  }
  final x = jwk['x'];
  final y = jwk['y'];
  if (x is! String || y is! String) return null;
  final Uint8List xb;
  final Uint8List yb;
  try {
    xb = base64UrlDecodeLoose(x);
    yb = base64UrlDecodeLoose(y);
  } on FormatException {
    return null;
  }
  if (xb.length != 32 || yb.length != 32) return null;
  final xi = _int(xb);
  final yi = _int(yb);
  if (xi >= _p || yi >= _p) return null;
  final left = (yi * yi) % _p;
  final right = (xi * xi * xi - BigInt.from(3) * xi + _b) % _p;
  if (left != right) return null;
  return _domain.curve.createPoint(xi, yi);
}

BigInt _int(Uint8List bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

bool _verifies(pc.ECPoint point, List<int> message, Uint8List signature) {
  if (signature.length != 64) return false;
  final verifier = pc.ECDSASigner(pc.SHA256Digest())
    ..init(
      false,
      pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(point, _domain)),
    );
  return verifier.verifySignature(
    Uint8List.fromList(message),
    pc.ECSignature(_int(signature.sublist(0, 32)), _int(signature.sublist(32))),
  );
}
