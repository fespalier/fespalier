import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'signer.dart';

/// base64url without padding (RFC 7515 section 2).
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// The bytes of a base64url string, with or without padding.
Uint8List base64UrlDecodeLoose(String value) =>
    base64Url.decode(base64Url.normalize(value));

/// The RFC 7638 thumbprint of a P-256 public key given as a JWK (since 0.21.0; it was in
/// `fespalier_sign_keypair`): the base64url SHA-256 of
/// `{"crv":"P-256","kty":"EC","x":"...","y":"..."}`, with those members in that order and no
/// white space.
///
/// Throws an [ArgumentError] when [jwk] is not an EC P-256 public key.
String jwkThumbprint(Map<String, Object?> jwk) {
  final x = jwk['x'];
  final y = jwk['y'];
  if (jwk['kty'] != 'EC' ||
      jwk['crv'] != 'P-256' ||
      x is! String ||
      y is! String) {
    throw ArgumentError.value(
      jwk.keys.toList(),
      'jwk',
      'fespalier_keypair: not an EC P-256 public key (kty, crv, x and y are needed)',
    );
  }
  final canonical = jsonEncode(<String, String>{
    'crv': 'P-256',
    'kty': 'EC',
    'x': x,
    'y': y,
  });
  return base64UrlNoPad(sha256.convert(utf8.encode(canonical)).bytes);
}

/// A compact JWS (RFC 7515): `base64url(header).base64url(payload).base64url(signature)`, the
/// signature made by [signer] over the first two parts (since 0.21.0).
///
/// The header and the payload are encoded as they are, members in the order given: nothing is
/// added, so the caller says `alg`, `typ` and `jwk`. [reason] is what a
/// `KeyRole.userPresent` key captions its prompt with.
///
/// Throws a [StateError] when [signer] returns something other than a 64-byte `r||s` signature,
/// which is all that ES256 is.
Future<String> compactJws(
  Map<String, Object?> header,
  Map<String, Object?> payload,
  KeypairSigner signer, {
  String? reason,
}) async {
  final signingInput =
      '${base64UrlNoPad(utf8.encode(jsonEncode(header)))}'
      '.${base64UrlNoPad(utf8.encode(jsonEncode(payload)))}';
  final signature = await signer.sign(
    Uint8List.fromList(utf8.encode(signingInput)),
    reason: reason,
  );
  if (signature.length != 64) {
    throw StateError(
      'fespalier_keypair: the signer returned ${signature.length} bytes, not the '
      '64-byte r||s signature that ES256 needs',
    );
  }
  return '$signingInput.${base64UrlNoPad(signature)}';
}
