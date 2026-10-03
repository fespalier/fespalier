// DpopProof against a real Keycloak, with the realm of examples/auth (its client
// `fespalier-auth-example-dpop` requires DPoP-bound tokens). Skipped unless FESPALIER_KEYCLOAK_URL
// names a running one, so `flutter test` stays offline and deterministic:
//
//   docker run --rm -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
//     -v "$PWD/../../examples/auth/keycloak:/opt/keycloak/data/import:ro" \
//     quay.io/keycloak/keycloak:26.8.0 start-dev --import-realm
//   FESPALIER_KEYCLOAK_URL=http://localhost:8080 flutter test test/keycloak_live_test.dart
//
// It checks what the unit tests can only assume: that Keycloak accepts the proofs (typ, alg, jwk,
// htm, htu, iat, jti, ath) and binds the tokens to the key (`cnf.jkt`), that a proof is good once,
// and what it says about the clock (read from Keycloak 26.8.0).
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/oidc.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

final String? base = Platform.environment['FESPALIER_KEYCLOAK_URL'];

/// Fills in Keycloak's login form as ada, and returns the redirect it ends with. The cookies are
/// the ones a browser would keep (Keycloak marks them Secure even on http://localhost).
Future<Uri> headlessLogin(Uri url, Uri redirect) async {
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
    final html = await page.stream.bytesToString();
    final action = RegExp(
      r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"',
    ).firstMatch(html)?.group(1)?.replaceAll('&amp;', '&');
    if (action == null) fail('no login form at $url (HTTP ${page.statusCode})');
    final post = http.Request('POST', Uri.parse(action))
      ..bodyFields = {'username': 'ada', 'password': 'ada', 'credentialId': ''};
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

OidcBackend backend(
  DpopProof? proof, {
  String clientId = 'fespalier-auth-example-dpop',
}) => OidcBackend(
  issuer: Uri.parse('$base/realms/fespalier'),
  clientId: clientId,
  redirectUri: Uri.parse('com.example.fespalierauth:/callback'),
  openBrowser: headlessLogin,
  proof: proof,
);

Map<String, Object?> claimsOf(String jwt) =>
    jsonDecode(utf8.decode(unb64u(jwt.split('.')[1]))) as Map<String, Object?>;

void main() {
  final skip = base == null
      ? 'set FESPALIER_KEYCLOAK_URL to run against Keycloak'
      : null;
  final userinfo = Uri.parse(
    '$base/realms/fespalier/protocol/openid-connect/userinfo',
  );

  test(
    'signs in with a software key: Keycloak binds the tokens to it (cnf.jkt), and refreshes',
    () async {
      final dpop = DpopProof(signer: SoftwareDpopSigner());
      final oidc = backend(dpop);
      final thumbprint = await dpop.thumbprint();
      final session = await oidc.signIn(const BrowserSignIn());
      expect(session.tokens.tokenType, 'DPoP');
      expect(session.tokens.isDpop, isTrue);
      expect(session.binding, thumbprint);
      expect(
        (claimsOf(session.tokens.accessToken)['cnf']! as Map)['jkt'],
        thumbprint,
      );

      final next = await oidc.refresh(session);
      expect(next.tokens.accessToken, isNot(session.tokens.accessToken));
      expect(next.binding, thumbprint);
      expect(
        next.tokens.refreshToken,
        isNot(session.tokens.refreshToken),
        reason: 'rotated',
      );
    },
    skip: skip,
  );

  test(
    'the DPoP scheme with a proof that has ath is accepted at the userinfo endpoint; Bearer is not',
    () async {
      final dpop = DpopProof(signer: SoftwareDpopSigner());
      final session = await backend(dpop).signIn(const BrowserSignIn());
      final token = session.tokens.accessToken;
      final ok = await http.get(
        userinfo,
        headers: {
          'Authorization': 'DPoP $token',
          ...await dpop.headers(
            method: 'GET',
            uri: userinfo,
            accessToken: token,
          ),
        },
      );
      expect(ok.statusCode, 200);
      expect(jsonDecode(ok.body), containsPair('preferred_username', 'ada'));
      // The query string is not part of htu.
      final withQuery = userinfo.replace(queryParameters: {'x': '1'});
      final query = await http.get(
        withQuery,
        headers: {
          'Authorization': 'DPoP $token',
          ...await dpop.headers(
            method: 'GET',
            uri: withQuery,
            accessToken: token,
          ),
        },
      );
      expect(query.statusCode, 200);

      final bearer = await http.get(
        userinfo,
        headers: {'Authorization': 'Bearer $token'},
      );
      expect(bearer.statusCode, 401);
      expect(bearer.headers['www-authenticate'], contains('invalid_token'));
      final noProof = await http.get(
        userinfo,
        headers: {'Authorization': 'DPoP $token'},
      );
      expect(noProof.statusCode, 401);
      expect(noProof.headers['www-authenticate'], startsWith('DPoP '));
      expect(
        noProof.headers['www-authenticate'],
        contains('error="invalid_token"'),
      );
      // No ath: refused.
      final noAth = await http.get(
        userinfo,
        headers: {
          'Authorization': 'DPoP $token',
          ...await dpop.headers(method: 'GET', uri: userinfo),
        },
      );
      expect(noAth.statusCode, 401);
    },
    skip: skip,
  );

  test(
    'a proof is good once: the same proof twice is invalid_request, DPoP proof has already been used',
    () async {
      final dpop = DpopProof(signer: SoftwareDpopSigner());
      final oidc = backend(dpop);
      final session = await oidc.signIn(const BrowserSignIn());
      final tokenUri = Uri.parse(
        '$base/realms/fespalier/protocol/openid-connect/token',
      );
      final headers = await dpop.headers(method: 'POST', uri: tokenUri);
      Future<http.Response> refresh(String token) => http.post(
        tokenUri,
        headers: headers,
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': token,
          'client_id': 'fespalier-auth-example-dpop',
        },
      );
      final first = await refresh(session.tokens.refreshToken!);
      expect(first.statusCode, 200);
      final second = await refresh(
        (jsonDecode(first.body) as Map<String, Object?>)['refresh_token']!
            as String,
      );
      expect(second.statusCode, 400);
      expect(jsonDecode(second.body), {
        'error': 'invalid_request',
        'error_description': 'DPoP proof has already been used',
      });
    },
    skip: skip,
  );

  test(
    'a device clock that is wrong is invalid_request, DPoP proof is not active, and there is no Date to correct it with',
    () async {
      final dpop = DpopProof(signer: SoftwareDpopSigner());
      final oidc = backend(dpop);
      await expectLater(
        withClock(
          Clock.fixed(DateTime.now().add(const Duration(minutes: 5))),
          () => oidc.signIn(const BrowserSignIn()),
        ),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            'the token endpoint answered HTTP 400: invalid_request: DPoP proof is not active',
          ),
        ),
      );
      expect(dpop.clockOffset, Duration.zero);
    },
    skip: skip,
  );

  test(
    'a refresh token bound to another key is invalid_grant, DPoP confirmation does not match',
    () async {
      final dpop = DpopProof(signer: SoftwareDpopSigner());
      final oidc = backend(dpop);
      final session = await oidc.signIn(const BrowserSignIn());
      await dpop
          .reset(); // the key is gone: the next proof is signed by a new one
      await expectLater(
        oidc.refresh(session),
        throwsA(
          isA<AuthRejected>()
              .having((e) => e.error, 'error', 'invalid_grant')
              .having(
                (e) => e.description,
                'description',
                "DPoP confirmation doesn't match DPoP proof",
              ),
        ),
      );
    },
    skip: skip,
  );

  test(
    'a client that requires DPoP refuses a sign-in with no proof: DPoP proof is missing',
    () async {
      await expectLater(
        backend(null).signIn(const BrowserSignIn()),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            'the token endpoint answered HTTP 400: invalid_request: DPoP proof is missing',
          ),
        ),
      );
    },
    skip: skip,
  );

  test('sign-out revokes the refresh token, with a proof', () async {
    final dpop = DpopProof(signer: SoftwareDpopSigner());
    final oidc = backend(dpop);
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
  }, skip: skip);
}
