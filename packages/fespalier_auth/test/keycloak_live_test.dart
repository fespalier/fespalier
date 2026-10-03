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
import 'dart:io';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/oidc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final String? base = Platform.environment['FESPALIER_KEYCLOAK_URL'];

/// Fills in Keycloak's login form as [username], and returns the redirect it ends with.
Future<Uri> headlessLogin(
  Uri url,
  Uri redirect, {
  String username = 'ada',
  String password = 'ada',
}) async {
  final client = http.Client();
  final cookies = <String, String>{};
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.followRedirects = false;
    if (cookies.isNotEmpty) {
      request.headers['cookie'] = cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    final response = await client.send(request);
    final set = response.headers['set-cookie'];
    if (set != null) {
      for (final line in set.split(RegExp(r',(?=\s*[A-Za-z0-9_-]+=)'))) {
        final pair = line.trim().split(';').first.split('=');
        if (pair.length >= 2) cookies[pair.first] = pair.sublist(1).join('=');
      }
    }
    return response;
  }

  try {
    final page = await send(http.Request('GET', url));
    // prompt=none (and an error in the request) answers with the redirect at once, no form.
    final first = page.headers['location'];
    if (first != null) {
      await page.stream.drain<void>();
      return Uri.parse(first);
    }
    final html = await page.stream.bytesToString();
    final action = RegExp(
      r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"',
    ).firstMatch(html)?.group(1)?.replaceAll('&amp;', '&');
    if (action == null) fail('no login form at $url (HTTP ${page.statusCode})');
    final post = http.Request('POST', Uri.parse(action))
      ..bodyFields = {
        'username': username,
        'password': password,
        'credentialId': '',
      };
    final answer = await send(post);
    await answer.stream.drain<void>();
    final location = answer.headers['location'];
    if (location == null) {
      fail('the login did not redirect (HTTP ${answer.statusCode})');
    }
    return Uri.parse(location);
  } finally {
    client.close();
  }
}

OidcBackend backend({String clientId = 'fespalier-auth-example'}) {
  final issuer = Uri.parse('$base/realms/fespalier');
  return OidcBackend(
    issuer: issuer,
    clientId: clientId,
    redirectUri: Uri.parse('com.example.fespalierauth:/callback'),
    postLogoutRedirectUri: Uri.parse('com.example.fespalierauth:/logout'),
    openBrowser: headlessLogin,
  );
}

void main() {
  final skip = base == null
      ? 'set FESPALIER_KEYCLOAK_URL to run against Keycloak'
      : null;

  test('discovery finds the endpoints OidcEndpoints.keycloak spells', () async {
    final found = await OidcEndpoints.discover(
      Uri.parse('$base/realms/fespalier'),
    );
    final spelled = OidcEndpoints.keycloak(Uri.parse('$base/realms/fespalier'));
    expect(found.authorization, spelled.authorization);
    expect(found.token, spelled.token);
    expect(found.revocation, spelled.revocation);
    expect(found.endSession, spelled.endSession);
    expect(found.dpopAlgorithms, contains('ES256'));
  }, skip: skip);

  test(
    'signs in, refreshes with rotation, and a refresh token is good once',
    () async {
      final oidc = backend();
      final session = await oidc.signIn(const BrowserSignIn());
      expect(session.backend, 'oidc');
      expect(session.user.name, 'Ada Example');
      expect(session.user.email, 'ada@example.com');
      expect(session.user.roles, contains('admin'));
      expect(session.tokens.tokenType, 'Bearer');
      expect(session.tokens.refreshExpiresAt, isNotNull);

      final next = await oidc.refresh(session);
      expect(next.tokens.accessToken, isNot(session.tokens.accessToken));
      expect(
        next.tokens.refreshToken,
        isNot(session.tokens.refreshToken),
        reason: 'rotated',
      );
      expect(
        next.user,
        session.user,
        reason: 'a refresh that changes nothing about the user',
      );

      // The realm has "Revoke Refresh Token" on: the replaced token is refused, and Keycloak ends
      // the session for the replay (the next refresh says "Session doesn't have required client").
      await expectLater(
        oidc.refresh(session),
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
    'revocation ends the session: the refresh says Session not active',
    () async {
      final oidc = backend();
      final session = await oidc.signIn(const BrowserSignIn());
      await oidc.signOut(session);
      await expectLater(
        oidc.refresh(session),
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
        tokens: const AuthTokens(accessToken: 'a', refreshToken: 'not-a-token'),
      );
      await expectLater(
        oidc.refresh(fake),
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
      oidc.refresh(session),
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
        openBrowser: (url, back) async {
          opened = url;
          final client = http.Client();
          try {
            final request = http.Request('GET', url)..followRedirects = false;
            final response = await client.send(request);
            await response.stream.drain<void>();
            return Uri.parse(response.headers['location']!);
          } finally {
            client.close();
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
