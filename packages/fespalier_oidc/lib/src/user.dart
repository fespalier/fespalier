import 'package:fespalier_auth/fespalier_auth.dart';

/// The claims that change with every token, and would make every renewal look like another user.
const Set<String> volatileClaims = {
  'iat',
  'exp',
  'nbf',
  'auth_time',
  'jti',
  'at_hash',
  'c_hash',
  'sid',
  'session_state',
  'nonce',
  'typ',
  'azp',
};

/// An [AuthUser] from token claims (since 0.21.0; it was `AuthUser.fromClaims` in
/// `fespalier_auth`): the id is `sub`, `email` is `email` and `name` is `name`, else
/// `preferred_username`. The [volatileClaims] are dropped. Throws [FormatException] when there
/// is no `sub`.
AuthUser userFromClaims(
  Map<String, Object?> claims, {
  Set<String> roles = const {},
}) {
  final id = claims['sub'];
  if (id is! String || id.isEmpty) {
    throw const FormatException('fespalier_oidc: the token has no "sub" claim');
  }
  final email = claims['email'];
  final name = claims['name'] ?? claims['preferred_username'];
  return AuthUser(
    id: id,
    roles: roles,
    email: email is String ? email : null,
    name: name is String ? name : null,
    claims: {
      for (final e in claims.entries)
        if (!volatileClaims.contains(e.key)) e.key: e.value,
    },
  );
}
