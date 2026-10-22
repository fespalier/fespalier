// OidcBackend against a real Keycloak, with the realm of examples/auth. Skipped unless
// FESPALIER_KEYCLOAK_URL names a running one, so `flutter test` stays offline and deterministic:
//
//   docker run --rm -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
//     -v "$PWD/../../examples/auth/keycloak:/opt/keycloak/data/import:ro" \
//     quay.io/keycloak/keycloak:26.8.0 start-dev --import-realm
//   FESPALIER_KEYCLOAK_URL=http://localhost:8080 flutter test test/keycloak_live_test.dart
//
// The "browser" is a few HTTP requests that fill in Keycloak's login form, with the cookies a
// browser would keep (Keycloak marks them Secure even on http://localhost). It checks what the
// unit tests can only assume: the redirect carries `iss`, the ID token's issuer and audience, the
// roles are in the access token, and the errors are the ones OidcBackend maps (read from Keycloak
// 26.8.0, 2026-10-03).
//
// The package links neither package:http nor Dio, so the transport is a few lines over dart:io.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final String? base = Platform.environment['FESPALIER_KEYCLOAK_URL'];

/// An `HttpTransport` over `dart:io`'s `HttpClient`: enough for the token endpoint, discovery and
/// revocation. It does not follow redirects, as a transport under a token flow should not.
final class IoTransport implements HttpTransport {
  /// A transport with its own client, closed by [close].
  IoTransport() : _client = HttpClient();

  final HttpClient _client;

  /// Frees the sockets.
  void close() => _client.close(force: true);

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    try {
      final io = await _client.openUrl(request.method, request.uri);
      io.followRedirects = false;
      request.headers.forEach(io.headers.set);
      final body = request.body;
      if (body != null) io.add(body);
      final response = await io.close();
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      return TransportResponse.fromBytes(
        statusCode: response.statusCode,
        headers: headers,
        bytes: bytes.takeBytes(),
        reasonPhrase: response.reasonPhrase,
      );
    } on SocketException catch (e) {
      throw TransportUnsent(e, request.uri);
    } on TimeoutException catch (e) {
      throw TransportTimedOut(e, request.uri);
    } on HttpException catch (e) {
      throw TransportBroken(e, request.uri);
    }
  }
}

/// Fills in Keycloak's login form as [username], and returns the redirect it ends with.
Future<Uri> headlessLogin(
  Uri url,
  Uri redirect, {
  String username = 'ada',
  String password = 'ada',
}) async {
  final client = HttpClient();
  final cookies = <String, String>{};

  Future<(int, Map<String, String>, String)> send(
    String method,
    Uri uri, {
    String? form,
  }) async {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    if (cookies.isNotEmpty) {
      request.headers.set(
        'cookie',
        cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
    if (form != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.add(utf8.encode(form));
    }
    final response = await request.close();
    for (final cookie in response.cookies) {
      cookies[cookie.name] = cookie.value;
    }
    final text = await response.transform(utf8.decoder).join();
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(', ');
    });
    return (response.statusCode, headers, text);
  }

  try {
    final (pageStatus, pageHeaders, html) = await send('GET', url);
    // prompt=none (and an error in the request) answers with the redirect at once, no form.
    final first = pageHeaders['location'];
    if (first != null) return Uri.parse(first);
    final action = RegExp(
      r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"',
    ).firstMatch(html)?.group(1)?.replaceAll('&amp;', '&');
    if (action == null) fail('no login form at $url (HTTP $pageStatus)');
    final (answerStatus, answerHeaders, _) = await send(
      'POST',
      Uri.parse(action),
      form: Uri(
        queryParameters: {
          'username': username,
          'password': password,
          'credentialId': '',
        },
      ).query,
    );
    final location = answerHeaders['location'];
    if (location == null) {
      fail('the login did not redirect (HTTP $answerStatus)');
    }
    return Uri.parse(location);
  } finally {
    client.close(force: true);
  }
}

IoTransport? _transport;

OidcBackend backend({String clientId = 'fespalier-auth-example'}) {
  final issuer = Uri.parse('$base/realms/fespalier');
  return OidcBackend(
    issuer: issuer,
    clientId: clientId,
    redirectUri: Uri.parse('com.example.fespalierauth:/callback'),
    postLogoutRedirectUri: Uri.parse('com.example.fespalierauth:/logout'),
    openBrowser: headlessLogin,
    transport: _transport!,
  );
}

TokenCredential tokensOf(AuthSession session) =>
    session.credential as TokenCredential;

void main() {
  final skip = base == null
      ? 'set FESPALIER_KEYCLOAK_URL to run against Keycloak'
      : null;

  setUp(() => _transport = IoTransport());
  tearDown(() => _transport?.close());

  test('discovery finds the endpoints OidcEndpoints.keycloak spells', () async {
    final found = await OidcEndpoints.discover(
      Uri.parse('$base/realms/fespalier'),
      transport: _transport!,
    );
    final spelled = OidcEndpoints.keycloak(Uri.parse('$base/realms/fespalier'));
    expect(found.authorization, spelled.authorization);
    expect(found.token, spelled.token);
    expect(found.revocation, spelled.revocation);
    expect(found.endSession, spelled.endSession);
    expect(found.dpopAlgorithms, contains('ES256'));
  }, skip: skip);

  test(
    'signs in, renews with rotation, and a refresh token is good once',
    () async {
      final oidc = backend();
      final session = await oidc.signIn(const BrowserSignIn());
      expect(session.backend, 'oidc');
      expect(session.user.name, 'Ada Example');
      expect(session.user.email, 'ada@example.com');
      expect(session.user.roles, contains('admin'));
      expect(tokensOf(session).tokenType, 'Bearer');
      expect(tokensOf(session).refreshExpiresAt, isNotNull);

      final next = await oidc.renew(session);
      expect(tokensOf(next).accessToken, isNot(tokensOf(session).accessToken));
      expect(
        tokensOf(next).refreshToken,
        isNot(tokensOf(session).refreshToken),
        reason: 'rotated',
      );
      expect(
        next.user,
        session.user,
        reason: 'a renewal that changes nothing about the user',
      );

      // The realm has "Revoke Refresh Token" on: the replaced token is refused, and Keycloak ends
      // the session for the replay (the next renewal says "Session doesn't have required client").
      await expectLater(
        oidc.renew(session),
        throwsA(
          isA<AuthRejected>()
              .having((e) => e.error, 'error', 'invalid_grant')
              .having(
                (e) => e.description,
                'description',
                'Maximum allowed refresh token reuse exceeded',
              ),
        ),
      );
    },
    skip: skip,
  );

  test(
    'revocation ends the session: the renewal says Session not active',
    () async {
      final oidc = backend();
      final session = await oidc.signIn(const BrowserSignIn());
      await oidc.signOut(session);
      await expectLater(
        oidc.renew(session),
        throwsA(
          isA<AuthRejected>().having(
            (e) => e.description,
            'description',
            'Session not active',
          ),
        ),
      );
    },
    skip: skip,
  );

  test(
    'a made-up refresh token is invalid_grant: Invalid refresh token',
    () async {
      final oidc = backend();
      final session = await oidc.signIn(const BrowserSignIn());
      final fake = session.copyWith(
        credential: const TokenCredential(
          accessToken: 'a',
          refreshToken: 'not-a-token',
        ),
      );
      await expectLater(
        oidc.renew(fake),
        throwsA(
          isA<AuthRejected>().having(
            (e) => e.description,
            'description',
            'Invalid refresh token',
          ),
        ),
      );
    },
    skip: skip,
  );

  test('an unknown client is invalid_client', () async {
    final oidc = backend(clientId: 'nope');
    final session = await backend().signIn(const BrowserSignIn());
    await expectLater(
      oidc.renew(session),
      throwsA(
        isA<AuthRejected>().having((e) => e.error, 'error', 'invalid_client'),
      ),
    );
  }, skip: skip);

  test(
    'an error redirect is mapped: prompt=none with no session is login_required',
    () async {
      final oidc = backend();
      await expectLater(
        oidc.signIn(const BrowserSignIn(prompt: 'none')),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            startsWith(
              'the server answered the sign-in with error login_required',
            ),
          ),
        ),
      );
    },
    skip: skip,
  );

  test(
    'the end-session endpoint ends up on the post-logout redirect',
    () async {
      final oidc = backend();
      final session = await oidc.signIn(const BrowserSignIn());
      Uri? opened;
      final withHook = OidcBackend(
        issuer: oidc.issuer,
        clientId: oidc.clientId,
        redirectUri: oidc.redirectUri,
        postLogoutRedirectUri: oidc.postLogoutRedirectUri,
        transport: _transport!,
        openBrowser: (url, back) async {
          opened = url;
          final client = HttpClient();
          try {
            final request = await client.getUrl(url);
            request.followRedirects = false;
            final response = await request.close();
            await response.drain<void>();
            return Uri.parse(response.headers.value('location')!);
          } finally {
            client.close(force: true);
          }
        },
      );
      await withHook.endBrowserSession(session);
      expect(opened!.queryParameters['client_id'], 'fespalier-auth-example');
      expect(
        opened!.queryParameters['post_logout_redirect_uri'],
        'com.example.fespalierauth:/logout',
      );
      expect(opened!.queryParameters, contains('id_token_hint'));
    },
    skip: skip,
  );
}
