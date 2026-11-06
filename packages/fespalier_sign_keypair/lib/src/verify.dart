import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/verify.dart';

import 'profile.dart';
import 'refusals.dart';

/// Why [verifyDeviceSignature] refused a request: the verifier's codes of Authkestra's
/// device-signature profile v1 (RFC-014 §5, since the release after 0.25.0; from 0.21.0 to 0.25.0
/// there were ten codes, one `mismatch` and `replay`, which clients still read as the profile's).
///
/// Every one of them is a `401` with `{"error": code}` and `WWW-Authenticate: DeviceSignature
/// error="<code>"` ([DeviceSignatureInvalid.statusCode], [DeviceSignatureInvalid.headers],
/// [DeviceSignatureInvalid.body]), and `webankRefusals` reads each as the profile says.
enum DeviceSignatureError {
  /// A header is missing or empty (an empty value is an absent credential). The client signs out
  /// (`keyLost`): it knows it sent both.
  missingCredential('missing_credential'),

  /// A credential is not a compact JWS of base64url JSON, a header has no `alg`, the attestation
  /// lacks a claim (`iss`, `sub`, `did`, `iat`, `exp`, `cnf.jkt`, `att`) or its `att` is not an
  /// object, or the signature lacks one (`iat`, `exp`, `jti`, `mth`, `pth`, `aud`).
  malformed('malformed'),

  /// An algorithm that is not allowed: `none`, an HMAC, a device key that is not ES256 (or EdDSA
  /// when the verifier takes it), an issuer key that is not ES256, EdDSA or RS256.
  badAlg('bad_alg'),

  /// The attestation's `iss` is not an issuer the verifier trusts.
  untrustedIssuer('untrusted_issuer'),

  /// The attestation's header has no `kid`, or names none of the issuer's keys (a key rotation:
  /// the client renews its attestation once).
  unknownKid('unknown_kid'),

  /// The attestation's signature does not verify with the issuer key its `kid` names.
  badAttestation('bad_attestation'),

  /// The attestation is not valid now (its `exp` passed, or its `iat` is ahead, by more than the
  /// skew). The client renews it and sends again, once.
  attestationExpired('attestation_expired'),

  /// The attestation's `att.status` is not `"active"` (or is absent). The client renews once.
  deviceNotActive('device_not_active'),

  /// The signature's `jwk` is missing, carries a private member, or is not a public key of the
  /// header's `alg`. The client signs out (`keyLost`).
  badJwk('bad_jwk'),

  /// The signature's `jwk` is not the key the attestation is bound to (`cnf.jkt`): the key is not
  /// the one enrolled. The client signs out (`keyLost`).
  keyNotBound('key_not_bound'),

  /// The signature does not verify with its `jwk`.
  badSignature('bad_signature'),

  /// The signature's `exp` has passed, or its `iat` is ahead, by more than the skew.
  signatureExpired('signature_expired'),

  /// The signature lives longer than the longest allowed (`exp - iat` over five minutes), or
  /// its `exp` is before its `iat`.
  lifetimeTooLong('lifetime_too_long'),

  /// `mth` is not the request's method.
  methodMismatch('method_mismatch'),

  /// `pth` is not the request's path, as sent.
  pathMismatch('path_mismatch'),

  /// `aud` is not the profile's audience.
  audienceMismatch('audience_mismatch'),

  /// `qsh` does not match the raw query, or is on one side only (a stripped query).
  queryMismatch('query_mismatch'),

  /// `bdh` does not match the exact body bytes, or is on one side only (a stripped body).
  bodyMismatch('body_mismatch'),

  /// The `jti` was already used, or the single-use memory could not be written (fail closed).
  replayDetected('replay_detected');

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

  /// For a `*_mismatch`: the claim that disagrees (`mth`, `pth`, `aud`, `qsh` or `bdh`).
  final String? claim;

  /// `error.code`.
  String get code => error.code;

  /// The status to answer with: `401`, for every code the verifier produces (since the release
  /// after 0.25.0).
  int get statusCode => 401;

  /// The headers to answer with: `content-type: application/json` and the `www-authenticate`
  /// challenge (since the release after 0.25.0).
  Map<String, String> get headers =>
      DeviceRefusals.headers(code, statusCode: statusCode);

  /// The body to answer with, exactly `{"error":"<code>"}` (since the release after 0.25.0).
  String get body => DeviceRefusals.body(code);

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

  /// The attestation's claims: `iss`, `sub`, `did`, `iat`, `exp`, `cnf` and `att`.
  final Map<String, Object?> attestationClaims;

  /// The signature's claims: `iat`, `exp`, `jti`, `mth`, `pth`, `qsh`, `bdh`, `aud`.
  final Map<String, Object?> claims;

  /// The public key that signed: `{crv, kty, x, y}` for ES256, `{crv, kty, x}` for EdDSA.
  final Map<String, String> jwk;

  /// The RFC 7638 thumbprint of [jwk]: the attestation's `cnf.jkt`.
  String get thumbprint => jwkThumbprint(jwk);

  /// The attestation's `sub`: who the device belongs to.
  String? get subject => attestationClaims['sub'] as String?;

  /// The attestation's `did`: which device.
  String? get deviceId => attestationClaims['did'] as String?;

  /// The attestation's `att` object: `status`, `role` and the application's own members (since
  /// the release after 0.25.0), unchanged.
  Map<String, Object?> get attributes =>
      attestationClaims['att']! as Map<String, Object?>;

  /// Which key signed, from `att.role` (since the release after 0.25.0): the user-present key
  /// only for the exact string `"user_present"`, the ambient key for anything else or nothing.
  KeyRole get role => roleOfAttestation(attributes);

  /// The signature's `jti`.
  String get jti => claims['jti']! as String;
}

/// The key role an attestation's `att` object names (profile v1 §3.3, since the release after
/// 0.25.0): [KeyRole.userPresent] for `role: "user_present"` exactly, [KeyRole.ambient] for any
/// other value or none, so an application's own `role` is never read as a presence proof.
KeyRole roleOfAttestation(Map<String, Object?> att) =>
    att['role'] == userPresentRole ? KeyRole.userPresent : KeyRole.ambient;

/// The `att.role` of an attestation for the user-present key, on the wire (since the release after
/// 0.25.0). Snake case: never `KeyRole.userPresent.name`.
const String userPresentRole = 'user_present';

/// The issuer algorithms of profile v1: ES256, EdDSA (Ed25519) and RS256.
const Set<String> profileIssuerAlgorithms = {'ES256', 'EdDSA', 'RS256'};

/// Checks a request the way a server does, and returns what it says (since 0.21.0; Authkestra's
/// device-signature profile v1 since the release after 0.25.0, with its conformance vectors in
/// `test/fixtures/devsig-profile-v1/`). Pure Dart, no plugin: a demo server and a test verify the
/// requests `DeviceSigner` signs with it.
///
/// [method], [uri] and [body] are the request as the server received it (the exact body bytes;
/// null or empty for none; a bare `?` is no query), [headers] its headers (names are matched
/// case-insensitively against [profile]; an empty value is an absent one), and [issuerKeys] the
/// issuer's public JWKs, **each with its `kid`** (a JWKS's `keys`). [trustedIssuers] are the
/// `iss` values accepted; null accepts any `iss` signed by one of [issuerKeys].
/// [issuerAlgorithms] (ES256, EdDSA and RS256 by default) and [deviceAlgorithms] (ES256 by
/// default: devices sign ES256, and a verifier MAY add `EdDSA`) are the allow-lists; `none` and
/// HMAC are refused whatever they say.
///
/// The checks, in the profile's order; the first that fails throws a [DeviceSignatureInvalid]:
///
/// 1. both headers are there and not empty (`missing_credential`);
/// 2. both are compact JWSs of JSON (`malformed`) with an allowed `alg` (`bad_alg`), and the
///    signature's header has a `jwk` (`bad_jwk`);
/// 3. the attestation has its claims and an `att` object (`malformed`), a trusted `iss`
///    (`untrusted_issuer`), a `kid` naming one of [issuerKeys] (`unknown_kid`), a signature by
///    that key (`bad_attestation`), is valid now within [skew] (`attestation_expired`) and its
///    `att.status` is `"active"` (`device_not_active`);
/// 4. the `jwk` is a public key of the `alg` (`bad_jwk`) whose thumbprint is `cnf.jkt`
///    (`key_not_bound`);
/// 5. the signature verifies with it (`bad_signature`) and has its claims (`malformed`);
/// 6. freshness: `exp` is not past, and `iat` not ahead, by [skew] or more (`signature_expired`),
///    and `exp - iat` is between 0 and [maxLifetime] (`lifetime_too_long`);
/// 7. `mth`, `pth`, `aud`, `qsh` and `bdh` match the request, each hash **present on both sides
///    or on neither** (`method_mismatch`, `path_mismatch`, `audience_mismatch`, `query_mismatch`,
///    `body_mismatch`);
/// 8. the `jti` is added to [seenJtis] (`replay_detected` when it was there, **or when adding it
///    throws**: a store that cannot be reached fails closed). It is added only when everything
///    else passed, so a refused request does not burn one.
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
  Iterable<String>? trustedIssuers,
  List<int>? body,
  Duration skew = const Duration(seconds: 30),
  Duration maxLifetime = DeviceSignatureProfile.maxLifetime,
  Set<String> issuerAlgorithms = profileIssuerAlgorithms,
  Set<String> deviceAlgorithms = const {'ES256'},
  DateTime? now,
}) {
  final at = (now ?? clock.now()).millisecondsSinceEpoch ~/ 1000;
  final tolerance = skew.inSeconds;

  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase() &&
          entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    return null;
  }

  // 1. Presence.
  final attestationJws = header(profile.attestationHeader);
  final signatureJws = header(profile.signatureHeader);
  if (attestationJws == null || signatureJws == null) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.missingCredential,
      'the attestation or the signature header is missing',
    );
  }

  // 2. Parse both, and their algorithms, before any cryptography.
  final attestation = _Jws.parse(attestationJws, 'attestation');
  final attestationAlg = _alg(
    attestation.header,
    issuerAlgorithms,
    'attestation',
  );
  final signature = _Jws.parse(signatureJws, 'signature');
  final signatureAlg = _alg(signature.header, deviceAlgorithms, 'signature');
  final embedded = signature.header['jwk'];
  if (embedded == null) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badJwk,
      'the signature header has no jwk',
    );
  }

  // 3. Attestation trust.
  final claims = attestation.payload;
  final cnf = claims['cnf'];
  final jkt = cnf is Map<String, Object?> ? cnf['jkt'] : null;
  final iss = claims['iss'];
  final iat = claims['iat'];
  final exp = claims['exp'];
  if (iss is! String ||
      claims['sub'] is! String ||
      claims['did'] is! String ||
      iat is! int ||
      exp is! int ||
      jkt is! String) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.malformed,
      'the attestation lacks iss, sub, did, iat, exp or cnf.jkt',
    );
  }
  final att = claims['att'];
  if (att is! Map<String, Object?>) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.malformed,
      'the attestation att claim is not a JSON object',
    );
  }
  if (trustedIssuers != null && !trustedIssuers.contains(iss)) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.untrustedIssuer,
      'the attestation names an issuer that is not trusted',
    );
  }
  final kid = attestation.header['kid'];
  final issuerKey = kid is! String
      ? null
      : issuerKeys.where((key) => key['kid'] == kid).firstOrNull;
  if (issuerKey == null) {
    throw DeviceSignatureInvalid(
      DeviceSignatureError.unknownKid,
      kid is! String
          ? 'the attestation header has no kid'
          : "the attestation's kid is not one of the issuer's keys",
    );
  }
  final keyAlg = issuerKey['alg'];
  if ((keyAlg != null && keyAlg != attestationAlg) ||
      !_verify(attestationAlg, issuerKey, attestation)) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badAttestation,
      "the attestation is not signed by the issuer key its kid names",
    );
  }
  if (at < iat - tolerance || at >= exp + tolerance) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.attestationExpired,
      'the attestation is not valid now',
    );
  }
  if (att['status'] != 'active') {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.deviceNotActive,
      'the attestation att.status is not "active"',
    );
  }

  // 4. The binding.
  final jwk = _deviceJwk(embedded, signatureAlg);
  if (jwk == null) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badJwk,
      "the jwk is not a public key of the signature's alg",
    );
  }
  if (!_constantTimeEquals(jwkThumbprint(jwk), jkt)) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.keyNotBound,
      "the jwk's thumbprint is not the attestation's cnf.jkt",
    );
  }

  // 5. The request signature.
  if (!_verify(signatureAlg, jwk, signature)) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.badSignature,
      'the signature does not verify',
    );
  }
  final signed = signature.payload;
  final signedIat = signed['iat'];
  final signedExp = signed['exp'];
  final jti = signed['jti'];
  final qsh = signed['qsh'];
  final bdh = signed['bdh'];
  if (signedIat is! int ||
      signedExp is! int ||
      jti is! String ||
      jti.isEmpty ||
      signed['mth'] is! String ||
      signed['pth'] is! String ||
      signed['aud'] is! String ||
      (qsh != null && qsh is! String) ||
      (bdh != null && bdh is! String)) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.malformed,
      'the signature lacks iat, exp, jti, mth, pth or aud',
    );
  }

  // 6. Freshness.
  if (at >= signedExp + tolerance) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.signatureExpired,
      'the signature has expired',
    );
  }
  if (signedIat - tolerance > at) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.signatureExpired,
      'the signature is dated in the future',
    );
  }
  final lifetime = signedExp - signedIat;
  if (lifetime < 0 || lifetime > maxLifetime.inSeconds) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.lifetimeTooLong,
      'the signature lives longer than allowed',
    );
  }

  // 7. The request.
  DeviceSignatureInvalid mismatch(DeviceSignatureError error, String claim) =>
      DeviceSignatureInvalid(
        error,
        '$claim does not match the request',
        claim: claim,
      );
  if (signed['mth'] != method.toUpperCase()) {
    throw mismatch(DeviceSignatureError.methodMismatch, 'mth');
  }
  if (signed['pth'] != (uri.path.isEmpty ? '/' : uri.path)) {
    throw mismatch(DeviceSignatureError.pathMismatch, 'pth');
  }
  if (signed['aud'] != profile.audience) {
    throw mismatch(DeviceSignatureError.audienceMismatch, 'aud');
  }
  if (!_hashMatches(uri.query.isEmpty ? null : utf8.encode(uri.query), qsh)) {
    throw mismatch(DeviceSignatureError.queryMismatch, 'qsh');
  }
  if (!_hashMatches(body == null || body.isEmpty ? null : body, bdh)) {
    throw mismatch(DeviceSignatureError.bodyMismatch, 'bdh');
  }

  // 8. Single use, last, failing closed.
  bool fresh;
  try {
    fresh = seenJtis.add(jti);
  } on Object {
    // The memory of jtis cannot be written: refuse exactly as a replay.
    fresh = false;
  }
  if (!fresh) {
    throw const DeviceSignatureInvalid(
      DeviceSignatureError.replayDetected,
      'the jti was already used',
    );
  }
  return VerifiedDeviceRequest(
    attestationClaims: claims,
    claims: signed,
    jwk: jwk,
  );
}

/// A compact JWS, split and decoded.
final class _Jws {
  const _Jws(this.header, this.payload, this.input, this.signature);

  /// Splits [jws] (the [what] credential): three segments, a header and a signature that are
  /// not empty, base64url JSON objects. Anything else is `malformed`.
  factory _Jws.parse(String jws, String what) {
    final parts = jws.split('.');
    if (parts.length != 3 || parts[0].isEmpty || parts[2].isEmpty) {
      throw DeviceSignatureInvalid(
        DeviceSignatureError.malformed,
        'the $what is not a compact JWS of three segments',
      );
    }
    try {
      return _Jws(
        _object(parts[0]),
        _object(parts[1]),
        utf8.encode('${parts[0]}.${parts[1]}'),
        base64UrlDecodeLoose(parts[2]),
      );
    } on FormatException {
      throw DeviceSignatureInvalid(
        DeviceSignatureError.malformed,
        'the $what is not made of base64url JSON objects',
      );
    }
  }

  final Map<String, Object?> header;
  final Map<String, Object?> payload;
  final List<int> input;
  final Uint8List signature;
}

/// The header's `alg` when it is in [allowed]: `malformed` without one, `bad_alg` for `none`, an
/// HMAC or anything outside the list.
String _alg(Map<String, Object?> header, Set<String> allowed, String what) {
  final alg = header['alg'];
  if (alg is! String) {
    throw DeviceSignatureInvalid(
      DeviceSignatureError.malformed,
      'the $what header has no alg',
    );
  }
  if (alg.toLowerCase() == 'none' ||
      alg.startsWith('HS') ||
      !allowed.contains(alg) ||
      !profileIssuerAlgorithms.contains(alg)) {
    throw DeviceSignatureInvalid(
      DeviceSignatureError.badAlg,
      'the $what alg is not allowed',
    );
  }
  return alg;
}

/// The device's public key from the signature header when it matches [alg] and carries no
/// private member; else null.
Map<String, String>? _deviceJwk(Object? jwk, String alg) {
  if (jwk is! Map<String, Object?>) return null;
  const private = {'d', 'p', 'q', 'dp', 'dq', 'qi', 'k'};
  if (private.any(jwk.containsKey)) return null;
  return switch (alg) {
    'ES256' => publicP256Jwk(jwk),
    'EdDSA' when publicEd25519Key(jwk) != null => <String, String>{
      'crv': 'Ed25519',
      'kty': 'OKP',
      'x': jwk['x']! as String,
    },
    _ => null,
  };
}

bool _verify(String alg, Map<String, Object?> key, _Jws jws) => switch (alg) {
  'ES256' => verifyEs256(key, jws.input, jws.signature),
  'EdDSA' => verifyEd25519(key, jws.input, jws.signature),
  'RS256' => verifyRs256(key, jws.input, jws.signature),
  _ => false,
};

bool _hashMatches(List<int>? bytes, Object? claim) {
  if (bytes == null || claim == null) return bytes == null && claim == null;
  return claim is String &&
      _constantTimeEquals(claim, sha256.convert(bytes).toString());
}

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

Map<String, Object?> _object(String part) {
  final decoded = jsonDecode(utf8.decode(base64UrlDecodeLoose(part)));
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('not a JSON object');
  }
  return decoded;
}
