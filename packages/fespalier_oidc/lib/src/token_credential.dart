import 'package:fespalier_auth/fespalier_auth.dart';

/// The tokens of a session: what an OpenID Connect or OAuth backend gets from the token endpoint
/// (since 0.21.0; it was `AuthTokens` in `fespalier_auth`). A [SessionCredential]: `toString`
/// never shows a token.
final class TokenCredential implements SessionCredential {
  /// Tokens with an [accessToken]; the rest is what the server returned.
  const TokenCredential({
    required this.accessToken,
    this.tokenType = 'Bearer',
    this.refreshToken,
    this.idToken,
    this.expiresAt,
    this.refreshExpiresAt,
    this.scope,
    this.jkt,
  });

  /// Reads what [toJson] wrote. Throws [FormatException] on anything else.
  factory TokenCredential.fromJson(Map<String, Object?> json) =>
      TokenCredential(
        accessToken: _string(json, 'accessToken')!,
        tokenType: _string(json, 'tokenType', required: false) ?? 'Bearer',
        refreshToken: _string(json, 'refreshToken', required: false),
        idToken: _string(json, 'idToken', required: false),
        expiresAt: _date(json, 'expiresAt'),
        refreshExpiresAt: _date(json, 'refreshExpiresAt'),
        scope: _string(json, 'scope', required: false),
        jkt: _string(json, 'jkt', required: false),
      );

  /// The token to send to the API.
  final String accessToken;

  /// `Bearer`, or `DPoP` for a DPoP-bound token (as the token response said).
  final String tokenType;

  /// What gets new tokens; null when the server gave none (the session ends with the access
  /// token).
  final String? refreshToken;

  /// The OpenID Connect ID token, when there is one.
  final String? idToken;

  /// When the access token expires (`expires_in`, read against `clock.now()`); null: unknown, so
  /// it is sent until a server answers 401.
  @override
  final DateTime? expiresAt;

  /// When the refresh token expires (Keycloak's `refresh_expires_in`; 0 means never); null:
  /// unknown.
  final DateTime? refreshExpiresAt;

  /// The scopes the server granted.
  final String? scope;

  /// The DPoP key thumbprint (RFC 7638) the tokens are bound to; null when they are not bound
  /// (it was `AuthSession.binding` before 0.21.0).
  final String? jkt;

  @override
  DateTime? get renewableUntil => refreshExpiresAt;

  @override
  bool get renewable => refreshToken != null;

  /// Whether the token type is DPoP (case-insensitive).
  bool get isDpop => tokenType.toLowerCase() == 'dpop';

  /// Whether the access token has expired at [now], counting [leeway] early.
  bool isExpiredAt(DateTime now, {Duration leeway = Duration.zero}) {
    final at = expiresAt;
    return at != null && !at.subtract(leeway).isAfter(now);
  }

  /// [renewed] over these: a refresh response that leaves out the refresh token or the ID token
  /// keeps this one's.
  TokenCredential merge(TokenCredential renewed) => TokenCredential(
    accessToken: renewed.accessToken,
    tokenType: renewed.tokenType,
    refreshToken: renewed.refreshToken ?? refreshToken,
    idToken: renewed.idToken ?? idToken,
    expiresAt: renewed.expiresAt,
    refreshExpiresAt: renewed.refreshToken == null
        ? refreshExpiresAt
        : renewed.refreshExpiresAt,
    scope: renewed.scope ?? scope,
    jkt: renewed.jkt,
  );

  /// These tokens bound to the key with thumbprint [jkt].
  TokenCredential bound(String? jkt) => TokenCredential(
    accessToken: accessToken,
    tokenType: tokenType,
    refreshToken: refreshToken,
    idToken: idToken,
    expiresAt: expiresAt,
    refreshExpiresAt: refreshExpiresAt,
    scope: scope,
    jkt: jkt,
  );

  @override
  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'tokenType': tokenType,
    'refreshToken': refreshToken,
    'idToken': idToken,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'refreshExpiresAt': refreshExpiresAt?.toUtc().toIso8601String(),
    'scope': scope,
    'jkt': jkt,
  };

  @override
  bool operator ==(Object other) =>
      other is TokenCredential &&
      other.accessToken == accessToken &&
      other.tokenType == tokenType &&
      other.refreshToken == refreshToken &&
      other.idToken == idToken &&
      other.expiresAt == expiresAt &&
      other.refreshExpiresAt == refreshExpiresAt &&
      other.scope == scope &&
      other.jkt == jkt;

  @override
  int get hashCode => Object.hash(
    accessToken,
    tokenType,
    refreshToken,
    idToken,
    expiresAt,
    refreshExpiresAt,
    scope,
    jkt,
  );

  @override
  String toString() =>
      'TokenCredential(type: $tokenType, expiresAt: ${expiresAt?.toUtc().toIso8601String()}, '
      'refresh: ${refreshToken == null ? 'no' : 'yes'}, id: ${idToken == null ? 'no' : 'yes'})';
}

String? _string(Map<String, Object?> json, String key, {bool required = true}) {
  final value = json[key];
  if (value is String) return value;
  if (value == null && !required) return null;
  throw FormatException('fespalier_oidc: "$key" is missing or not a string');
}

DateTime? _date(Map<String, Object?> json, String key) {
  final text = _string(json, key, required: false);
  if (text == null) return null;
  final date = DateTime.tryParse(text);
  if (date == null) {
    throw FormatException('fespalier_oidc: "$key" is not a date');
  }
  return date.toUtc();
}
