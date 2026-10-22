// DpopProof against a real Keycloak, with the realm of examples/auth (its client
// `fespalier-auth-example-dpop` requires DPoP-bound tokens). Skipped unless FESPALIER_KEYCLOAK_URL
// names a running one, so `flutter test` stays offline and deterministic:
//
//   docker run --rm -p 8080:8080 -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
//     -v "$PWD/../../examples/auth/keycloak:/opt/keycloak/data/import:ro" \
//     quay.io/keycloak/keycloak:26.8.0 start-dev --import-realm
//   FESPALIER_KEYCLOAK_URL=http://localhost:8080 flutter test test/keycloak_live_test.dart
//
// It sends through a small HttpTransport over dart:io's HttpClient, written in this file: no
// package:http. It checks what the unit tests can only assume: that Keycloak accepts the proofs
// (typ, alg, jwk, htm, htu, iat, jti, ath) and binds the tokens to the key (`cnf.jkt`), that a
// proof is good once, and what it says about the clock (read from Keycloak 26.8.0).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final String? base = Platform.environment['FESPALIER_KEYCLOAK_URL'];

/// What [LiveHttp.send] answers.
final class LiveResponse {
  LiveResponse(this.statusCode, this.headers, this.setCookies, this.bytes);

  final int statusCode;

  /// The headers with lower-case names; repeated ones joined with `, `.
  final Map<String, String> headers;

  /// The values of every `Set-Cookie` header, one per cookie.
  final List<String> setCookies;

  final Uint8List bytes;

  String get body => utf8.decode(bytes, allowMalformed: true);
}

/// A minimal HTTP client over dart:io, for this test only: redirects are never followed (the
/// headless login reads them).
final class LiveHttp {
  final HttpClient _client = HttpClient();

  Future<LiveResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final request = await _client.openUrl(method, uri);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body != null) request.add(body);
    final response = await request.close();
    final joined = <String, String>{};
    final cookies = <String>[];
    response.headers.forEach((name, values) {
      if (name == 'set-cookie') cookies.addAll(values);
      joined[name] = values.join(', ');
    });
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return LiveResponse(
      response.statusCode,
      joined,
      cookies,
      builder.takeBytes(),
    );
  }

  Future<LiveResponse> get(Uri uri, {Map<String, String> headers = const {}}) =>
      send('GET', uri, headers: headers);

  Future<LiveResponse> postForm(
    Uri uri,
    Map<String, String>? form, {
    Map<String, String> headers = const {},
  }) => send(
    'POST',
    uri,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      ...headers,
    },
    body: utf8.encode(Uri(queryParameters: form).query),
  );

  void close() => _client.close(force: true);
}

/// The [HttpTransport] the backend sends through.
final class IoTransport implements HttpTransport {
  IoTransport(this.http);

  final LiveHttp http;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final response = await http.send(
      request.method,
      request.uri,
      headers: request.headers,
      body: request.body,
    );
    return TransportResponse.fromBytes(
      statusCode: response.statusCode,
      headers: response.headers,
      bytes: response.bytes,
    );
  }
}

/// Fills in Keycloak's login form as ada, and returns the redirect it ends with. The cookies are
/// the ones a browser would keep (Keycloak marks them Secure even on http://localhost).
Future<Uri> headlessLogin(Uri url, Uri redirect) async {
  final client = LiveHttp();
  final cookies = <String, String>{};
  Future<LiveResponse> send(
    String method,
    Uri uri, {
    Map<String, String>? form,
  }) async {
    final headers = {
      if (cookies.isNotEmpty)
        'cookie': cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    };
    final response = form == null
        ? await client.get(uri, headers: headers)
        : await client.postForm(uri, form, headers: headers);
    for (final line in response.setCookies) {
      final pair = line.trim().split(';').first.split('=');
      if (pair.length >= 2) cookies[pair.first] = pair.sublist(1).join('=');
    }
    return response;
  }

  try {
    final page = await send('GET', url);
    final action = RegExp(
      r'<form[^>]*id="kc-form-login"[^>]*action="([^"]+)"',
    ).firstMatch(page.body)?.group(1)?.replaceAll('&amp;', '&');
    if (action == null) fail('no login form at $url (HTTP ${page.statusCode})');
    final answer = await send(
      'POST',
      Uri.parse(action),
      form: {'username': 'ada', 'password': 'ada', 'credentialId': ''},
    );
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
  DpopProof? proof,
  HttpTransport transport, {
  String clientId = 'fespalier-auth-example-dpop',
}) => OidcBackend(
  issuer: Uri.parse('$base/realms/fespalier'),
  clientId: clientId,
  redirectUri: Uri.parse('com.example.fespalierauth:/callback'),
  openBrowser: headlessLogin,
  transport: transport,
  proof: proof,
);

Map<String, Object?> claimsOf(String jwt) =>
    jsonDecode(utf8.decode(unb64u(jwt.split('.')[1]))) as Map<String, Object?>;

/// The tokens of a session this package's backend made.
TokenCredential tokensOf(AuthSession session) =>
    session.credential as TokenCredential;

void main() {
  final skip = base == null
      ? 'set FESPALIER_KEYCLOAK_URL to run against Keycloak'
      : null;
  final userinfo = Uri.parse(
    '$base/realms/fespalier/protocol/openid-connect/userinfo',
  );
  final tokenUri = Uri.parse(
    '$base/realms/fespalier/protocol/openid-connect/token',
  );

  late LiveHttp http;
  late IoTransport transport;
  setUp(() {
    http = LiveHttp();
    transport = IoTransport(http);
  });
  tearDown(() => http.close());

  test(
    'signs in with a software key: Keycloak binds the tokens to it (cnf.jkt), and refreshes',
    () async {
      final dpop = DpopProof(
        signer: SoftwareKeypairSigner(keyId: 'fespalier_dpop'),
      );
      final oidc = backend(dpop, transport);
      final thumbprint = await dpop.thumbprint();
      final session = await oidc.signIn(const BrowserSignIn());
      final tokens = tokensOf(session);
      expect(tokens.tokenType, 'DPoP');
      expect(tokens.isDpop, isTrue);
      expect(tokens.jkt, thumbprint);
      expect((claimsOf(tokens.accessToken)['cnf']! as Map)['jkt'], thumbprint);

      final next = tokensOf(await oidc.renew(session));
      expect(next.accessToken, isNot(tokens.accessToken));
      expect(next.jkt, thumbprint);
      expect(next.refreshToken, isNot(tokens.refreshToken), reason: 'rotated');
    },
    skip: skip,
  );

  test(
    'the DPoP scheme with a proof that has ath is accepted at the userinfo endpoint; Bearer is not',
    () async {
      final dpop = DpopProof(
        signer: SoftwareKeypairSigner(keyId: 'fespalier_dpop'),
      );
      final session = await backend(
        dpop,
        transport,
      ).signIn(const BrowserSignIn());
      final token = tokensOf(session).accessToken;
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
      final dpop = DpopProof(
        signer: SoftwareKeypairSigner(keyId: 'fespalier_dpop'),
      );
      final oidc = backend(dpop, transport);
      final session = await oidc.signIn(const BrowserSignIn());
      final headers = await dpop.headers(method: 'POST', uri: tokenUri);
      Future<LiveResponse> refresh(String token) => http.postForm(tokenUri, {
        'grant_type': 'refresh_token',
        'refresh_token': token,
        'client_id': 'fespalier-auth-example-dpop',
      }, headers: headers);
      final first = await refresh(tokensOf(session).refreshToken!);
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
      final dpop = DpopProof(
        signer: SoftwareKeypairSigner(keyId: 'fespalier_dpop'),
      );
      final oidc = backend(dpop, transport);
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
      final dpop = DpopProof(
        signer: SoftwareKeypairSigner(keyId: 'fespalier_dpop'),
      );
      final oidc = backend(dpop, transport);
      final session = await oidc.signIn(const BrowserSignIn());
      await dpop
          .reset(); // the key is gone: the next proof is signed by a new one
      await expectLater(
        oidc.renew(session),
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
        backend(null, transport).signIn(const BrowserSignIn()),
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
    final dpop = DpopProof(
      signer: SoftwareKeypairSigner(keyId: 'fespalier_dpop'),
    );
    final oidc = backend(dpop, transport);
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
  }, skip: skip);
}
