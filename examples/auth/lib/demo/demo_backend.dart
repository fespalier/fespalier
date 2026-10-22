import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// "Your own API": an `AuthBackend` over `POST /auth/login` and `POST /auth/refresh`, which answer
/// `{"access_token", "refresh_token", "expires_in", "user": {"id", "name", "roles"}}`. A wrong
/// password is a `FieldErrors`, which the sign-in form shows under its field; the server refusing
/// the refresh token is `AuthRejected` (the session is over); a socket error or a 5xx is anything
/// else, which keeps the session and is tried again.
///
/// It sends through the `HttpTransport` the app gives it (the one `AuthConfig.transport` is), and
/// it keeps what the API hands out as a `TokenCredential` that a `BearerAuthenticator` sends: a
/// backend whose tokens are bearer tokens needs no authenticator of its own.
///
/// Copy it and change the paths: it is the recipe for a backend of your own, and the only thing
/// the rest of the app knows of it is `AuthBackend`.
final class DemoBackend extends AuthBackend {
  /// A backend that talks to [base] through [transport].
  DemoBackend(this.base, this.transport);

  /// The API's origin.
  final Uri base;

  /// What the requests go through.
  final HttpTransport transport;

  @override
  String get name => 'demo';

  @override
  String get scheme => 'bearer';

  @override
  final Duration renewAhead = const Duration(seconds: 30);

  @override
  final BearerAuthenticator authenticator = const BearerAuthenticator();

  @override
  TokenCredential readCredential(Map<String, Object?> json) =>
      TokenCredential.fromJson(json);

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! PasswordSignIn) {
      throw UnsupportedError('DemoBackend signs in with PasswordSignIn');
    }
    final answer = await _post('/auth/login', {
      'username': request.username,
      'password': request.password,
    });
    if (answer.status == 401) {
      throw const FieldErrors({'password': 'Wrong user name or password'});
    }
    return _session(answer.json);
  }

  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) async {
    final credential = session.credential as TokenCredential;
    final answer = await _post('/auth/refresh', {
      'refresh_token': credential.refreshToken,
    });
    if (answer.status == 400 || answer.status == 401) {
      throw const AuthRejected();
    }
    return _session(answer.json, previous: session);
  }

  @override
  Future<void> signOut(AuthSession session) async {
    final credential = session.credential as TokenCredential;
    await _post('/auth/logout', {'refresh_token': credential.refreshToken});
  }

  Future<({int status, Map<String, Object?> json})> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final response = await transport.send(
      TransportRequest(
        method: 'POST',
        uri: base.resolve(path),
        headers: const {'content-type': 'application/json'},
        body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      ),
    );
    final text = utf8.decode(await response.bytes());
    if (response.statusCode >= 500) {
      // Not a refusal: the session stays, and the next request asks again.
      throw AuthUnavailable('HTTP ${response.statusCode}');
    }
    return (
      status: response.statusCode,
      json: text.isEmpty
          ? const <String, Object?>{}
          : jsonDecode(text) as Map<String, Object?>,
    );
  }

  AuthSession _session(Map<String, Object?> json, {AuthSession? previous}) {
    final user = json['user'] as Map<String, Object?>?;
    return AuthSession(
      backend: name,
      credential: TokenCredential(
        accessToken: json['access_token']! as String,
        refreshToken: json['refresh_token'] as String?,
        // clock.now(), not DateTime.now(): a test's fake clock ages the token.
        expiresAt: clock.now().add(
          Duration(seconds: json['expires_in']! as int),
        ),
      ),
      user: user == null
          ? previous!.user
          : AuthUser(
              id: user['id']! as String,
              name: user['name'] as String?,
              roles: {...(user['roles']! as List<Object?>).cast<String>()},
            ),
    );
  }
}
