import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:http/http.dart' as http;

/// "Your own API": an `AuthBackend` over `POST /auth/login` and `POST /auth/refresh`, which answer
/// `{"access_token", "refresh_token", "expires_in", "user": {"id", "name", "roles"}}`. A wrong
/// password is a `FieldErrors`, which the sign-in form shows under its field; the server refusing
/// the refresh token is `AuthRejected` (the session is over); a socket error or a 5xx is anything
/// else, which keeps the session and is tried again.
///
/// Copy it and change the paths: it is the recipe for a backend of your own, and the only thing
/// the rest of the app knows of it is `AuthBackend`.
final class DemoBackend extends AuthBackend {
  /// A backend that talks to [base] through [client].
  DemoBackend(this.base, this.client);

  /// The API's origin.
  final Uri base;

  /// What the requests go through (a `MockClient` in the demo).
  final http.Client client;

  @override
  String get name => 'demo';

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! PasswordSignIn) {
      throw UnsupportedError('DemoBackend signs in with PasswordSignIn');
    }
    final response = await _post('/auth/login', {
      'username': request.username,
      'password': request.password,
    });
    if (response.statusCode == 401) {
      throw const FieldErrors({'password': 'Wrong user name or password'});
    }
    return _session(response);
  }

  @override
  Future<AuthSession> refresh(AuthSession session) async {
    final response = await _post('/auth/refresh', {
      'refresh_token': session.tokens.refreshToken,
    });
    if (response.statusCode == 400 || response.statusCode == 401) {
      throw const AuthRejected();
    }
    return _session(response, previous: session);
  }

  @override
  Future<void> signOut(AuthSession session) async {
    await _post('/auth/logout', {'refresh_token': session.tokens.refreshToken});
  }

  Future<http.Response> _post(String path, Map<String, Object?> body) async {
    final uri = base.resolve(path);
    final response = await client.post(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode >= 500) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    return response;
  }

  AuthSession _session(http.Response response, {AuthSession? previous}) {
    final json = jsonDecode(response.body) as Map<String, Object?>;
    final user = json['user'] as Map<String, Object?>?;
    return AuthSession(
      backend: name,
      tokens: AuthTokens(
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
