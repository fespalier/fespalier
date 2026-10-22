import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';

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

/// The `ath` claim for [accessToken] (RFC 9449 section 4.2): the base64url SHA-256 of its ASCII
/// bytes (since 0.9.0).
String accessTokenHash(String accessToken) =>
    base64UrlNoPad(sha256.convert(ascii.encode(accessToken)).bytes);
