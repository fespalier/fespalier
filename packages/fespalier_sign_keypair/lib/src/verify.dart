import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/verify.dart';

import 'attestation.dart';
import 'profile.dart';

/// Why [verifyDeviceSignature] refused a request (since 0.21.0). The [code]s are the ones
/// `webankRefusals` reads, where they overlap, so a demo server can answer `{"error": code}` and
/// the client does the right thing.
enum DeviceSignatureError {
  /// The attestation or the signature header is missing, or is not a compact JWS.
  missingCredential('missing_credential'),

  /// The attestation is not signed by an issuer key the server trusts, or its claims are not
  /// readable.
  badAttestation('bad_attestation'),

  /// The attestation's `exp` has passed. The client renews it and sends again.
  attestationExpired('attestation_expired'),

  /// The signature's `jwk` is not a public P-256 key on the curve, or the header's `alg` is not
  /// ES256.
  badJwk('bad_jwk'),

  /// The signature's `jwk` is not the key the attestation is bound to (`cnf.jkt`). The key is not
  /// the one enrolled; the client signs out.
  keyNotBound('key_not_bound'),

  /// The signature does not verify with the `jwk`, or its claims are not readable.
  badSignature('bad_signature'),

  /// The signature's `exp` has passed (beyond the allowed skew), or its `iat` is further in the
  /// future than the skew.
  signatureExpired('signature_expired'),

  /// The signature lives longer than the longest allowed (`exp - iat` over five minutes).
  lifetimeTooLong('lifetime_too_long'),

  /// A claim does not match the request: `mth`, `pth`, `aud`, `qsh` or `bdh` (a hash present on
  /// one side only counts). `DeviceSignatureInvalid.claim` says which.
  mismatch('mismatch'),

  /// The `jti` was already used.
  replay('replay');

  const DeviceSignatureError(this.code);

  /// The wire name: what a server answers in `{"error": ...}`.
  final String code;
}

/// A request that [verifyDeviceSignature] refused: the first check that failed (since 0.21.0).
///
/// `toString` is `DeviceSignatureInvalid: <code>: <message>`. The message never carries an
/// attestation, a signature or a key.
final class DeviceSignatureInvalid implements Exception {
  /// A refusal for [error], in a sentence, for the request's [claim] when it is a mismatch.
  const DeviceSignatureInvalid(this.error, this.message, {this.claim});

  /// Which check failed.
  final DeviceSignatureError error;

  /// The check, in a sentence.
  final String message;

  /// For [DeviceSignatureError.mismatch]: the claim that disagrees (`mth`, `pth`, `aud`, `qsh`
  /// or `bdh`).
  final String? claim;

  /// `error.code`.
  String get code => error.code;

  @override
  String toString() => 'DeviceSignatureInvalid: $code: $message';
}

/// A request that [verifyDeviceSignature] accepted (since 0.21.0).
final class VerifiedDeviceRequest {
  /// What a verified request says.
  const VerifiedDeviceRequest({
    required this.attestationClaims,
    required this.claims,
    required this.jwk,
  });

  /// The attestation's claims: `iss`, `sub`, `did`, `iat`, `exp`, `cnf` and the status.
  final Map<String, Object?> attestationClaims;

  /// The signature's claims: `iat`, `exp`, `jti`, `mth`, `pth`, `qsh`, `bdh`, `aud`.
  final Map<String, Object?> claims;

  /// The public key that signed, as `{crv, kty, x, y}`.
  final Map<String, String> jwk;

  /// The RFC 7638 thumbprint of [jwk]: the attestation's `cnf.jkt`.
  String get thumbprint => jwkThumbprint(jwk);

  /// The attestation's `sub`: who the device belongs to.
  String? get subject => attestationClaims['sub'] as String?;

  /// The attestation's `did`: which device.
  String? get deviceId => attestationClaims['did'] as String?;

  /// The signature's `jti`.
  String get jti => claims['jti']! as String;
}

/// Checks a request the way a server does, and returns what it says (since 0.21.0). Pure Dart, no
/// plugin: a demo server and a test verify the requests `DeviceSigner` signs with it.
///
/// [method], [uri] and [body] are the request as the server received it (the exact body bytes;
/// null or empty for none), [headers] its headers (names are matched case-insensitively against
/// [profile]), and [issuerKeys] the JWKs the issuer's attestations are verified with.
///
/// The checks, in order; the first that fails throws a [DeviceSignatureInvalid] with its code:
///
/// 1. both headers are there (`missing_credential`);
/// 2. the attestation is a compact JWS signed by one of [issuerKeys] (`bad_attestation`) and has
///    not expired (`attestation_expired`);
/// 3. the signature's header has `alg` ES256 and a public P-256 `jwk` (`bad_jwk`);
/// 4. that `jwk`'s thumbprint is the attestation's `cnf.jkt` (`key_not_bound`);
/// 5. the signature verifies with the `jwk` (`bad_signature`);
/// 6. freshness: `exp` is not past, and `iat` is not ahead, by more than [skew] (30 s by default)
///    (`signature_expired`), and `exp - iat` is at most [maxLifetime] (`lifetime_too_long`);
/// 7. `mth` is [method], `pth` is the path, `aud` is the profile's audience, and `qsh` and `bdh`
///    are the lower-case hex SHA-256 of the raw query and of the body, each **present on both
///    sides or on neither** (`mismatch`, with the claim named);
/// 8. the `jti` is not in [seenJtis] (`replay`); it is added to it only when everything passed,
///    so a refused request does not burn one.
///
/// [seenJtis] is the caller's single-use memory: a set that outlives [skew] plus [maxLifetime] is
/// enough. [now] is `clock.now()` by default.
VerifiedDeviceRequest verifyDeviceSignature({
  required String method,
  required Uri uri,
  required Map<String, String> headers,
  required DeviceSignatureProfile profile,
  required Iterable<Map<String, Object?>> issuerKeys,
  required Set<String> seenJtis,
  List<int>? body,
  Duration skew = const Duration(seconds: 30),
  Duration maxLifetime = DeviceSignatureProfile.maxLifetime,
  DateTime? now,
}) {
  final at = (now ?? clock.now()).millisecondsSinceEpoch ~/ 1000;

  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  final attestationJws = header(profile.attestationHeader);
  final signatureJws = header(profile.signatureHeader);
  if (attestationJws == null ||
      attestationJws.isEmpty ||
      signatureJws == null ||
      signatureJws.isEmpty) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.missingCredential,
      'the attestation or the signature header is missing',
    );
  }

  // 1. The attestation.
  final attestationParts = _parts(attestationJws);
  if (attestationParts == null) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badAttestation,
      'the attestation is not a compact JWS',
    );
  }
  final Map<String, Object?> attestationHeader;
  final Map<String, Object?> attestationClaims;
  final Uint8List attestationSignature;
  try {
    attestationHeader = _object(attestationParts[0]);
    attestationClaims = _object(attestationParts[1]);
    attestationSignature = base64UrlDecodeLoose(attestationParts[2]);
  } on FormatException {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badAttestation,
      'the attestation is not made of base64url JSON parts',
    );
  }
  final attestationInput = utf8.encode(
    '${attestationParts[0]}.${attestationParts[1]}',
  );
  if (attestationHeader['alg'] != 'ES256' ||
      !issuerKeys.any(
        (key) => verifyEs256(key, attestationInput, attestationSignature),
      )) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badAttestation,
      "the attestation is not signed by the issuer's key",
    );
  }
  final Attestation attestation;
  try {
    attestation = Attestation.parse(attestationJws);
  } on FormatException {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badAttestation,
      'the attestation has no exp or no cnf.jkt',
    );
  }
  if (attestation.expiresAt.millisecondsSinceEpoch ~/ 1000 <= at) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.attestationExpired,
      'the attestation has expired',
    );
  }

  // 2. The key.
  final signatureParts = _parts(signatureJws);
  if (signatureParts == null) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badSignature,
      'the signature is not a compact JWS',
    );
  }
  final Map<String, Object?> signatureHeader;
  final Map<String, Object?> claims;
  final Uint8List signature;
  try {
    signatureHeader = _object(signatureParts[0]);
    claims = _object(signatureParts[1]);
    signature = base64UrlDecodeLoose(signatureParts[2]);
  } on FormatException {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badSignature,
      'the signature is not made of base64url JSON parts',
    );
  }
  final jwk = publicP256Jwk(signatureHeader['jwk']);
  if (signatureHeader['alg'] != 'ES256' || jwk == null) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badJwk,
      'the jwk is not a public P-256 key, or alg is not ES256',
    );
  }
  if (jwkThumbprint(jwk) != attestation.jkt) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.keyNotBound,
      "the jwk's thumbprint is not the attestation's cnf.jkt",
    );
  }

  // 3. The signature.
  if (!verifyEs256(
    jwk,
    utf8.encode('${signatureParts[0]}.${signatureParts[1]}'),
    signature,
  )) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badSignature,
      'the signature does not verify',
    );
  }

  // 4. Freshness.
  final iat = claims['iat'];
  final exp = claims['exp'];
  if (iat is! num || exp is! num) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badSignature,
      'iat or exp is missing',
    );
  }
  if (exp.toInt() + skew.inSeconds <= at) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.signatureExpired,
      'the signature has expired',
    );
  }
  if (iat.toInt() - skew.inSeconds > at) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.signatureExpired,
      'the signature is dated in the future',
    );
  }
  if (exp.toInt() - iat.toInt() > maxLifetime.inSeconds) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.lifetimeTooLong,
      'the signature lives longer than allowed',
    );
  }

  // 5. The request.
  DeviceSignatureInvalid mismatch(String claim) => DeviceSignatureInvalid(
    DeviceSignatureError.mismatch,
    '$claim does not match the request',
    claim: claim,
  );
  if (claims['mth'] != method.toUpperCase()) throw mismatch('mth');
  if (claims['pth'] != (uri.path.isEmpty ? '/' : uri.path)) {
    throw mismatch('pth');
  }
  if (claims['aud'] != profile.audience) throw mismatch('aud');
  if (claims['qsh'] !=
      (uri.query.isEmpty ? null : _hex(utf8.encode(uri.query)))) {
    throw mismatch('qsh');
  }
  if (claims['bdh'] != (body == null || body.isEmpty ? null : _hex(body))) {
    throw mismatch('bdh');
  }

  // 6. Single use.
  final jti = claims['jti'];
  if (jti is! String || jti.isEmpty) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badSignature,
      'jti is missing',
    );
  }
  if (!seenJtis.add(jti)) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.replay,
      'the jti was already used',
    );
  }
  return VerifiedDeviceRequest(
    attestationClaims: attestationClaims,
    claims: claims,
    jwk: jwk,
  );
}

List<String>? _parts(String jws) {
  final parts = jws.split('.');
  return parts.length != 3 || parts.any((p) => p.isEmpty) ? null : parts;
}

Map<String, Object?> _object(String part) {
  final decoded = jsonDecode(utf8.decode(base64UrlDecodeLoose(part)));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('not a JSON object');
  }
  return decoded;
}

String _hex(List<int> bytes) => sha256.convert(bytes).toString();
