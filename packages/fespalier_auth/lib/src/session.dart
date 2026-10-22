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

  /// The session: its credential and its user.
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

  /// The server refused to renew the session, or the stored one had expired.
  expired,

  /// The device key the credential was bound to is gone, or another one.
  keyLost,

  /// The server says this device or session is revoked (since 0.21.0).
  revoked,
}

/// Who is signed in. Equality is deep over every field, so a renewal that changes nothing
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

  /// The account's stable id (a token's `sub` claim, for instance).
  final String id;

  /// What the user may do, as the backend names it.
  final Set<String> roles;

  /// The rest of what the backend knows about the user (a token's claims, without the ones that
  /// change with every token).
  final Map<String, Object?> claims;

  /// The e-mail address, when the backend knows it.
  final String? email;

  /// The display name, when the backend knows it.
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

/// What proves a session to the API (since 0.21.0). Each scheme has its own: `TokenCredential`
/// (`package:fespalier_oidc`) holds an access token, `DeviceCredential`
/// (`package:fespalier_sign_keypair`) a device attestation. `fespalier_auth` knows only this
/// interface, so it never reads a token and never signs anything.
///
/// Equality is value-based (a credential a server rejected is compared with the one the session
/// holds now), and `toString` never shows a secret.
abstract interface class SessionCredential {
  /// When it stops working unless renewed; null: unknown, so it is used until a server says 401.
  DateTime? get expiresAt;

  /// When renewal itself is no longer possible (a refresh token's expiry); null: unknown, or
  /// never. `restoreAuth` drops a session past it as `SignOutReason.expired`.
  DateTime? get renewableUntil;

  /// Whether the backend can renew it without the user (a refresh token, a device key).
  bool get renewable;

  /// JSON-encodable, for the store; `AuthBackend.readCredential` reads it back.
  Map<String, Object?> toJson();
}

/// A signed-in session: what the token store keeps.
final class AuthSession {
  /// A session made by the backend [backend], for [user], proved by [credential].
  const AuthSession({
    required this.backend,
    required this.credential,
    required this.user,
  });

  /// Reads what [toJson] wrote, the credential through [readCredential] (the backend's). Throws
  /// [FormatException] on anything else, an unknown `"v"` included: a session stored by 0.20.0
  /// and before (`"v": 1`) is not read, and its user signs in once more.
  static AuthSession fromJson(
    Map<String, Object?> json,
    SessionCredential Function(Map<String, Object?> json) readCredential,
  ) {
    if (json['v'] != 2) {
      throw FormatException(
        'fespalier_auth: unknown stored session version ${json['v']}',
      );
    }
    final credential = json['credential'];
    final user = json['user'];
    if (credential is! Map<String, Object?> || user is! Map<String, Object?>) {
      throw const FormatException(
        'fespalier_auth: a stored session is malformed',
      );
    }
    return AuthSession(
      backend: _string(json, 'backend')!,
      credential: readCredential(credential),
      user: AuthUser.fromJson(user),
    );
  }

  /// The `AuthBackend.name` that made it. `restoreAuth` drops a session of another backend.
  final String backend;

  /// What proves it to the API.
  final SessionCredential credential;

  /// Who is signed in.
  final AuthUser user;

  /// This session with a new [credential] or a new [user].
  AuthSession copyWith({SessionCredential? credential, AuthUser? user}) =>
      AuthSession(
        backend: backend,
        credential: credential ?? this.credential,
        user: user ?? this.user,
      );

  /// `{"v": 2, "backend": …, "credential": {…}, "user": {…}}`.
  Map<String, Object?> toJson() => {
    'v': 2,
    'backend': backend,
    'credential': credential.toJson(),
    'user': user.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is AuthSession &&
      other.backend == backend &&
      other.credential == credential &&
      other.user == user;

  @override
  int get hashCode => Object.hash(backend, credential, user);

  @override
  String toString() => 'AuthSession(backend: $backend, $credential, $user)';
}

String? _string(Map<String, Object?> json, String key, {bool required = true}) {
  final value = json[key];
  if (value is String) return value;
  if (value == null && !required) return null;
  throw FormatException('fespalier_auth: "$key" is missing or not a string');
}
