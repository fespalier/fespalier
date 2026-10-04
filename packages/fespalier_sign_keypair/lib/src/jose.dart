import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// base64url without padding (RFC 7515 section 2).
String base64UrlNoPadding(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// The bytes of a base64url string, with or without padding.
Uint8List base64UrlDecodeLoose(String value) =>
    base64Url.decode(base64Url.normalize(value));

/// The `htu` claim of a DPoP proof for a request to [uri] (RFC 9449 section 4.2): the target URI
/// without its query and fragment (since 0.9.0).
///
/// The scheme and the host are lower-case, the default port (80 for `http`, 443 for `https`) is
/// left out, an empty path is `/`, an IPv6 host stays in brackets and the path keeps its
/// percent-encoding.
String dpopHtu(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final bracketed = host.contains(':') ? '[$host]' : host;
  final defaultPort = switch (scheme) {
    'http' => 80,
    'https' => 443,
    _ => null,
  };
  final port = uri.hasPort && uri.port != defaultPort ? ':${uri.port}' : '';
  final path = uri.path.isEmpty ? '/' : uri.path;
  return '$scheme://$bracketed$port$path';
}

/// The RFC 7638 thumbprint of a P-256 public key given as a JWK (since 0.9.0): the base64url
/// SHA-256 of `{"crv":"P-256","kty":"EC","x":"...","y":"..."}`, with those members in that
/// order and no white space.
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
      'fespalier_sign_keypair: not an EC P-256 public key (kty, crv, x and y are needed)',
    );
  }
  final canonical = jsonEncode(<String, String>{
    'crv': 'P-256',
    'kty': 'EC',
    'x': x,
    'y': y,
  });
  return base64UrlNoPadding(sha256.convert(utf8.encode(canonical)).bytes);
}

/// The `ath` claim for [accessToken] (RFC 9449 section 4.2): the base64url SHA-256 of its ASCII
/// bytes (since 0.9.0).
String accessTokenHash(String accessToken) =>
    base64UrlNoPadding(sha256.convert(ascii.encode(accessToken)).bytes);
