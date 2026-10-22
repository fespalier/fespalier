import 'dart:convert';

import 'package:fespalier_keypair/fespalier_keypair.dart';

/// What the issuer says about one device key (since 0.21.0): a compact JWS signed by the issuer
/// with the claims `iss`, `sub`, `did`, `iat`, `exp`, `cnf.jkt` (the RFC 7638 thumbprint of the
/// key it is bound to) and a status. On its own it proves nothing: it counts only next to a fresh
/// signature by the bound key. It is sent unchanged in the attestation header.
///
/// The client never verifies it (it has no issuer key to): [expiresAt] and [jkt] are read from the
/// claims without checking the signature, to know when to renew and which key it belongs to.
/// `toString` shows neither the JWS nor the thumbprint.
final class Attestation {
  const Attestation._(this.jws, this.expiresAt, this.jkt);

  /// Reads the claims of [jws] (a compact JWS) without verifying it. Throws a [FormatException]
  /// when it is not three base64url parts with a JSON object in the middle that has a numeric
  /// `exp` and a `cnf.jkt`.
  factory Attestation.parse(String jws) {
    final parts = jws.split('.');
    if (parts.length != 3 || parts.any((p) => p.isEmpty)) {
      throw const FormatException(
        'fespalier_sign_keypair: an attestation is a compact JWS of three parts',
      );
    }
    final Object? claims;
    try {
      claims = jsonDecode(utf8.decode(base64UrlDecodeLoose(parts[1])));
    } on FormatException {
      throw const FormatException(
        'fespalier_sign_keypair: the attestation claims are not base64url JSON',
      );
    }
    if (claims is! Map<String, Object?>) {
      throw const FormatException(
        'fespalier_sign_keypair: the attestation claims are not a JSON object',
      );
    }
    final exp = claims['exp'];
    final cnf = claims['cnf'];
    final jkt = cnf is Map<String, Object?> ? cnf['jkt'] : null;
    if (exp is! num || jkt is! String || jkt.isEmpty) {
      throw const FormatException(
        'fespalier_sign_keypair: the attestation has no numeric exp or no cnf.jkt',
      );
    }
    return Attestation._(
      jws,
      DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000, isUtc: true),
      jkt,
    );
  }

  /// The compact JWS, as the server issued it.
  final String jws;

  /// When it stops being accepted: its `exp` claim.
  final DateTime expiresAt;

  /// The thumbprint of the key it is bound to: its `cnf.jkt` claim.
  final String jkt;

  @override
  bool operator ==(Object other) => other is Attestation && other.jws == jws;

  @override
  int get hashCode => jws.hashCode;

  @override
  String toString() => 'Attestation(expires ${expiresAt.toIso8601String()})';
}
