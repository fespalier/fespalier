import 'dart:convert';
import 'dart:typed_data';

/// The payload of [token] if it is a JWT, **not verified** (since 0.9.0).
///
/// For display and routing only: a role read here decides which screen to show, never whether a
/// request is allowed, which is the server's. Returns null when [token] is not three
/// base64url segments whose second is a JSON object.
///
/// ```dart
/// final claims = unverifiedJwtClaims(tokens.accessToken);
/// final roles = claims?['roles'];
/// ```
Map<String, Object?>? unverifiedJwtClaims(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final json = jsonDecode(utf8.decode(base64UrlDecode(parts[1])));
    if (json is! Map<String, Object?>) return null;
    return json;
  } on FormatException {
    return null;
  }
}

/// Base64url without padding, as JWTs and PKCE write it.
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding. Throws [FormatException] on anything else.
Uint8List base64UrlDecode(String text) =>
    base64Url.decode(base64Url.normalize(text));
