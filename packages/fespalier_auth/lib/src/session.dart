import 'package:collection/collection.dart';

/// Where the session is (since 0.9.0). Sealed: switch on it.
///
/// ```dart
/// final label = switch (ref.watch(authSession)) {
///   SessionRestoring() => 'Loading…',
///   SignedOut(:final reason) => reason == SignOutReason.expired ? 'Session over' : 'Signed out',
///   SignedIn(:final session) => 'Hello ${session.user.name}',
/// };
/// ```
sealed class SessionState {
  /// A state; the subclasses are [SessionRestoring], [SignedOut] and [SignedIn].
  const SessionState();

  /// Whether this is [SignedIn].
  bool get isSignedIn => this is SignedIn;

  /// The signed-in user, or null.
  AuthUser? get user => switch (this) {
    SignedIn(:final session) => session.user,
    _ => null,
  };
}

/// The stored session is being read. Only seen by an app that does not return
/// `restoreAuth(...)` from `startup()`: the guard helpers wait for it.
final class SessionRestoring extends SessionState {
  /// The state while the stored session is read.
  const SessionRestoring();

  @override
  String toString() => 'SessionRestoring()';
}

/// Nobody is signed in. [reason] says why, when somebody was.
final class SignedOut extends SessionState {
  /// Signed out, because of [reason] when there is one (null at a first start).
  const SignedOut({this.reason});

  /// Why the session ended; null when nobody was signed in before.
  final SignOutReason? reason;

  @override
  bool operator ==(Object other) =>
      other is SignedOut && other.reason == reason;

  @override
  int get hashCode => Object.hash(SignedOut, reason);

  @override
  String toString() => 'SignedOut(${reason?.name ?? ''})';
}

/// Somebody is signed in.
final class SignedIn extends SessionState {
  /// Signed in with [session].
  const SignedIn(this.session);

  /// The session: its tokens, its user and what they are bound to.
  final AuthSession session;

  @override
  bool operator ==(Object other) =>
      other is SignedIn && other.session == session;

  @override
  int get hashCode => Object.hash(SignedIn, session);

  @override
  String toString() => 'SignedIn($session)';
}

/// Why a session ended.
enum SignOutReason {
  /// `signOut()` was called.
  user,

  /// The server refused the refresh token, or the stored one had expired.
  expired,

  /// The device key the tokens were bound to (DPoP) is gone, or another one.
  keyLost,
}

/// The tokens of a session. `toString` never shows a token.
final class AuthTokens {
  /// Tokens with an [accessToken]; the rest is what the server returned.
  const AuthTokens({
    required this.accessToken,
    this.tokenType = 'Bearer',
    this.refreshToken,
    this.idToken,
    this.expiresAt,
    this.refreshExpiresAt,
    this.scope,
  });

  /// Reads what [toJson] wrote. Throws [FormatException] on anything else.
  factory AuthTokens.fromJson(Map<String, Object?> json) => AuthTokens(
    accessToken: _string(json, 'accessToken')!,
    tokenType: _string(json, 'tokenType', required: false) ?? 'Bearer',
    refreshToken: _string(json, 'refreshToken', required: false),
    idToken: _string(json, 'idToken', required: false),
    expiresAt: _date(json, 'expiresAt'),
    refreshExpiresAt: _date(json, 'refreshExpiresAt'),
    scope: _string(json, 'scope', required: false),
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
  final DateTime? expiresAt;

  /// When the refresh token expires (Keycloak's `refresh_expires_in`; 0 means never); null:
  /// unknown.
  final DateTime? refreshExpiresAt;

  /// The scopes the server granted.
  final String? scope;

  /// Whether the token type is DPoP (case-insensitive).
  bool get isDpop => tokenType.toLowerCase() == 'dpop';

  /// Whether the access token has expired at [now], counting [leeway] early.
  bool isExpiredAt(DateTime now, {Duration leeway = Duration.zero}) {
    final at = expiresAt;
    return at != null && !at.subtract(leeway).isAfter(now);
  }

  /// [refreshed] over these: a refresh response that leaves out the refresh token or the ID
  /// token keeps this one's.
  AuthTokens merge(AuthTokens refreshed) => AuthTokens(
    accessToken: refreshed.accessToken,
    tokenType: refreshed.tokenType,
    refreshToken: refreshed.refreshToken ?? refreshToken,
    idToken: refreshed.idToken ?? idToken,
    expiresAt: refreshed.expiresAt,
    refreshExpiresAt: refreshed.refreshToken == null
        ? refreshExpiresAt
        : refreshed.refreshExpiresAt,
    scope: refreshed.scope ?? scope,
  );

  /// JSON-encodable, for the token store.
  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'tokenType': tokenType,
    'refreshToken': refreshToken,
    'idToken': idToken,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'refreshExpiresAt': refreshExpiresAt?.toUtc().toIso8601String(),
    'scope': scope,
  };

  @override
  bool operator ==(Object other) =>
      other is AuthTokens &&
      other.accessToken == accessToken &&
      other.tokenType == tokenType &&
      other.refreshToken == refreshToken &&
      other.idToken == idToken &&
      other.expiresAt == expiresAt &&
      other.refreshExpiresAt == refreshExpiresAt &&
      other.scope == scope;

  @override
  int get hashCode => Object.hash(
    accessToken,
    tokenType,
    refreshToken,
    idToken,
    expiresAt,
    refreshExpiresAt,
    scope,
  );

  @override
  String toString() =>
      'AuthTokens(type: $tokenType, expiresAt: ${expiresAt?.toUtc().toIso8601String()}, '
      'refresh: ${refreshToken == null ? 'no' : 'yes'}, id: ${idToken == null ? 'no' : 'yes'})';
}

/// Who is signed in. Equality is deep over every field, so a token refresh that changes nothing
/// about the user does not notify `authUser`'s listeners.
final class AuthUser {
  /// A user with [id]; [roles], [claims], [email] and [name] when known.
  const AuthUser({
    required this.id,
    this.roles = const <String>{},
    this.claims = const <String, Object?>{},
    this.email,
    this.name,
  });

  /// From token claims: the id is `sub`, [email] is `email` and [name] is `name`, else
  /// `preferred_username`. The [volatileClaims] are dropped.
  factory AuthUser.fromClaims(
    Map<String, Object?> claims, {
    Set<String> roles = const {},
  }) {
    final id = claims['sub'];
    if (id is! String || id.isEmpty) {
      throw const FormatException(
        'fespalier_auth: the token has no "sub" claim',
      );
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

  /// Reads what [toJson] wrote. Throws [FormatException] on anything else.
  factory AuthUser.fromJson(Map<String, Object?> json) {
    final roles = json['roles'];
    final claims = json['claims'];
    if (roles is! List<Object?> || claims is! Map<String, Object?>) {
      throw const FormatException('fespalier_auth: a stored user is malformed');
    }
    return AuthUser(
      id: _string(json, 'id')!,
      roles: {
        for (final r in roles)
          if (r is String)
            r
          else
            throw const FormatException(
              'fespalier_auth: a stored role is not a string',
            ),
      },
      claims: claims,
      email: _string(json, 'email', required: false),
      name: _string(json, 'name', required: false),
    );
  }

  /// The claims that change with every token, and would make every refresh look like another
  /// user.
  static const Set<String> volatileClaims = {
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

  /// The account's stable id (the `sub` claim).
  final String id;

  /// What the user may do, as the backend names it.
  final Set<String> roles;

  /// The rest of what the token said, without the [volatileClaims].
  final Map<String, Object?> claims;

  /// The e-mail address, when the token has one.
  final String? email;

  /// The display name, when the token has one.
  final String? name;

  /// Whether [role] is one of [roles].
  bool hasRole(String role) => roles.contains(role);

  /// JSON-encodable, for the token store.
  Map<String, Object?> toJson() => {
    'id': id,
    'roles': roles.toList()..sort(),
    'claims': claims,
    'email': email,
    'name': name,
  };

  static const DeepCollectionEquality _deep = DeepCollectionEquality();

  @override
  bool operator ==(Object other) =>
      other is AuthUser &&
      other.id == id &&
      other.email == email &&
      other.name == name &&
      _deep.equals(other.roles, roles) &&
      _deep.equals(other.claims, claims);

  @override
  int get hashCode =>
      Object.hash(id, email, name, _deep.hash(roles), _deep.hash(claims));

  /// No id, no claims and no e-mail: a log line is not for personal data.
  @override
  String toString() =>
      'AuthUser(roles: {${(roles.toList()..sort()).join(', ')}})';
}

/// A signed-in session: what the token store keeps.
final class AuthSession {
  /// A session made by the backend [backend], for [user].
  const AuthSession({
    required this.backend,
    required this.tokens,
    required this.user,
    this.binding,
  });

  /// Reads what [toJson] wrote. Throws [FormatException] on anything else, an unknown `"v"`
  /// included.
  factory AuthSession.fromJson(Map<String, Object?> json) {
    if (json['v'] != 1) {
      throw FormatException(
        'fespalier_auth: unknown stored session version ${json['v']}',
      );
    }
    final tokens = json['tokens'];
    final user = json['user'];
    if (tokens is! Map<String, Object?> || user is! Map<String, Object?>) {
      throw const FormatException(
        'fespalier_auth: a stored session is malformed',
      );
    }
    return AuthSession(
      backend: _string(json, 'backend')!,
      tokens: AuthTokens.fromJson(tokens),
      user: AuthUser.fromJson(user),
      binding: _string(json, 'binding', required: false),
    );
  }

  /// The `AuthBackend.name` that made it. `restoreAuth` drops a session of another backend.
  final String backend;

  /// The access token and the rest.
  final AuthTokens tokens;

  /// Who is signed in.
  final AuthUser user;

  /// The DPoP key thumbprint (RFC 7638) the tokens are bound to; null when they are not bound.
  final String? binding;

  /// This session with new [tokens] or a new [user].
  AuthSession copyWith({AuthTokens? tokens, AuthUser? user}) => AuthSession(
    backend: backend,
    tokens: tokens ?? this.tokens,
    user: user ?? this.user,
    binding: binding,
  );

  /// `{"v": 1, "backend": …, "tokens": {…}, "user": {…}, "binding": …}`.
  Map<String, Object?> toJson() => {
    'v': 1,
    'backend': backend,
    'tokens': tokens.toJson(),
    'user': user.toJson(),
    'binding': binding,
  };

  @override
  bool operator ==(Object other) =>
      other is AuthSession &&
      other.backend == backend &&
      other.tokens == tokens &&
      other.user == user &&
      other.binding == binding;

  @override
  int get hashCode => Object.hash(backend, tokens, user, binding);

  @override
  String toString() => 'AuthSession(backend: $backend, $tokens, $user)';
}

String? _string(Map<String, Object?> json, String key, {bool required = true}) {
  final value = json[key];
  if (value is String) return value;
  if (value == null && !required) return null;
  throw FormatException('fespalier_auth: "$key" is missing or not a string');
}

DateTime? _date(Map<String, Object?> json, String key) {
  final text = _string(json, key, required: false);
  if (text == null) return null;
  final date = DateTime.tryParse(text);
  if (date == null) {
    throw FormatException('fespalier_auth: "$key" is not a date');
  }
  return date.toUtc();
}
