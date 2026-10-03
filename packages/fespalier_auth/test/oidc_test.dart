// OidcBackend on a MockClient: the authorization URL, PKCE, every check of the redirect and of the
// ID token, the code exchange, refresh with rotation, the errors and what DPoP adds.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/oidc.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

final issuer = Uri.parse('https://sso.example.com/realms/shop');
final redirectUri = Uri.parse('com.example.shop:/callback');
final endpoints = OidcEndpoints.keycloak(issuer);
const clientId = 'shop-app';

/// A JWT built at run time (never a committed literal: secret scanners flag them).
String jwt(Map<String, Object?> claims) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'RS256', 'typ': 'JWT'})}.${part(claims)}.c2ln';
}

/// What a fake Keycloak is, and what it saw.
final class Server {
  final List<http.Request> requests = [];

  /// The `nonce` the last authorization URL carried: the ID token echoes it.
  String? nonce;

  Map<String, Object?> idClaims = {};
  Map<String, Object?> accessClaims = {};
  Map<String, Object?> extra = {};
  int status = 200;
  Object? body;
  Object? Function(http.Request request)? answer;
  int tokens = 0;

  Map<String, Object?> tokenResponse() {
    tokens++;
    return {
      'access_token': jwt({
        'sub': 'u-1',
        'realm_access': {
          'roles': ['admin', 'offline_access'],
        },
        'resource_access': {
          clientId: {
            'roles': ['buyer'],
          },
          'account': {
            'roles': ['manage-account'],
          },
        },
        'jti': 'a$tokens',
        ...accessClaims,
      }),
      'expires_in': 300,
      'refresh_expires_in': 1800,
      'refresh_token': 'refresh-$tokens',
      'token_type': 'Bearer',
      'id_token': jwt({
        'iss': issuer.toString(),
        'aud': clientId,
        'sub': 'u-1',
        'name': 'Ada Example',
        'email': 'ada@example.com',
        'nonce': nonce,
        'iat': tokens,
        ...idClaims,
      }),
      'scope': 'openid profile email',
      ...extra,
    };
  }

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    if (request.url.path.endsWith('openid-configuration')) {
      return http.Response(
        jsonEncode({
          'issuer': issuer.toString(),
          'authorization_endpoint': endpoints.authorization.toString(),
          'token_endpoint': endpoints.token.toString(),
          'revocation_endpoint': endpoints.revocation.toString(),
          'end_session_endpoint': endpoints.endSession.toString(),
          'dpop_signing_alg_values_supported': ['ES256', 'RS256'],
        }),
        200,
      );
    }
    final custom = answer?.call(request);
    final payload = custom ?? body ?? tokenResponse();
    return http.Response(
      jsonEncode(payload),
      status,
      headers: {'content-type': 'application/json'},
    );
  });

  List<http.Request> get posts => [
    for (final r in requests)
      if (r.method == 'POST') r,
  ];
}

/// A browser that is sent back to the redirect with [params] over a good code and state.
Future<Uri> Function(Uri, Uri) browser(
  Server server, {
  Map<String, String> params = const {},
  Set<String> without = const {},
  List<Uri>? opened,
}) => (url, redirect) async {
  opened?.add(url);
  server.nonce = url.queryParameters['nonce'];
  final query = {
    'code': 'the-code',
    'state': url.queryParameters['state']!,
    'iss': issuer.toString(),
    ...params,
  }..removeWhere((k, _) => without.contains(k));
  return redirect.replace(queryParameters: query);
};

OidcBackend backend(
  Server server, {
  Future<Uri> Function(Uri, Uri)? openBrowser,
  OidcEndpoints? known,
  ProofOfPossession? proof,
  bool bindCodeToKey = true,
  int seed = 1,
  List<String> scopes = const ['openid', 'profile', 'email'],
}) => OidcBackend(
  issuer: issuer,
  clientId: clientId,
  redirectUri: redirectUri,
  openBrowser: openBrowser ?? browser(server),
  endpoints: known ?? endpoints,
  client: server.client,
  proof: proof,
  bindCodeToKey: bindCodeToKey,
  scopes: scopes,
  random: Random(seed),
);

const signIn = BrowserSignIn();

void main() {
  group('the authorization request', () {
    test(
      'has every parameter, S256, and the PKCE challenge of the verifier it exchanges',
      () async {
        final server = Server();
        final opened = <Uri>[];
        final oidc = backend(
          server,
          openBrowser: browser(server, opened: opened),
        );
        await oidc.signIn(signIn);
        final url = opened.single;
        expect(
          url.toString(),
          startsWith(
            'https://sso.example.com/realms/shop/protocol/openid-connect/auth?',
          ),
        );
        final p = url.queryParameters;
        expect(p['response_type'], 'code');
        expect(p['client_id'], clientId);
        expect(p['redirect_uri'], 'com.example.shop:/callback');
        expect(p['scope'], 'openid profile email');
        expect(p['code_challenge_method'], 'S256');
        expect(p.keys, isNot(contains('dpop_jkt')));
        expect(p.keys, isNot(contains('login_hint')));
        expect(p.keys, isNot(contains('prompt')));
        final form = server.posts.single.bodyFields;
        final verifier = form['code_verifier']!;
        expect(verifier, hasLength(43));
        expect(verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(
          p['code_challenge'],
          base64Url
              .encode(sha256.convert(ascii.encode(verifier)).bytes)
              .replaceAll('=', ''),
        );
        expect(p['state'], hasLength(22));
        expect(p['nonce'], hasLength(22));
        expect(p['state'], isNot(p['nonce']));
      },
    );

    test('RFC 7636 appendix B: the challenge of the example verifier', () {
      // The example of RFC 7636 appendix B, so a regression in the hash is caught by a vector
      // that does not come from this package.
      expect(
        base64Url
            .encode(
              sha256
                  .convert(
                    ascii.encode('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
                  )
                  .bytes,
            )
            .replaceAll('=', ''),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('a seeded random is deterministic, and two sign-ins differ', () async {
      Future<(String, String)> run(int seed) async {
        final server = Server();
        final opened = <Uri>[];
        await backend(
          server,
          openBrowser: browser(server, opened: opened),
          seed: seed,
        ).signIn(signIn);
        return (
          opened.single.queryParameters['state']!,
          server.posts.single.bodyFields['code_verifier']!,
        );
      }

      expect(await run(7), await run(7));
      expect(await run(7), isNot(await run(8)));
      final server = Server();
      final oidc = backend(server);
      await oidc.signIn(signIn);
      await oidc.signIn(signIn);
      expect(
        server.posts[0].bodyFields['code_verifier'],
        isNot(server.posts[1].bodyFields['code_verifier']),
      );
    });

    test(
      'login_hint, prompt and extra parameters go along, the extras last',
      () async {
        final server = Server();
        final opened = <Uri>[];
        await backend(
          server,
          openBrowser: browser(server, opened: opened),
        ).signIn(
          const BrowserSignIn(
            loginHint: 'ada',
            prompt: 'login',
            parameters: {
              'kc_idp_hint': 'google',
              'ui_locales': 'fr',
              'prompt': 'consent',
            },
          ),
        );
        final p = opened.single.queryParameters;
        expect(p['login_hint'], 'ada');
        expect(p['kc_idp_hint'], 'google');
        expect(p['ui_locales'], 'fr');
        expect(
          p['prompt'],
          'consent',
          reason: 'request.parameters are applied last',
        );
      },
    );

    test('scopes are space-joined', () async {
      final server = Server();
      final opened = <Uri>[];
      await backend(
        server,
        openBrowser: browser(server, opened: opened),
        scopes: const ['openid', 'offline_access'],
      ).signIn(signIn);
      expect(opened.single.queryParameters['scope'], 'openid offline_access');
    });

    test('only a BrowserSignIn: anything else is the error of M9', () async {
      final backend0 = backend(Server());
      await expectLater(
        backend0.signIn(const PasswordSignIn(username: 'a', password: 'b')),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            'fespalier_auth: OidcBackend signs in with BrowserSignIn, not PasswordSignIn',
          ),
        ),
      );
    });
  });

  group('the redirect', () {
    Future<void> fails(Server server, OidcBackend oidc, String message) =>
        expectLater(
          oidc.signIn(signIn),
          throwsA(
            isA<OidcException>().having((e) => e.message, 'message', message),
          ),
        );

    test('O1: a state that is not the one the sign-in sent', () async {
      final server = Server();
      await fails(
        server,
        backend(
          server,
          openBrowser: browser(server, params: {'state': 'forged'}),
        ),
        "the redirect's state does not match the sign-in that opened it",
      );
      expect(server.posts, isEmpty, reason: 'no code is exchanged');
    });

    test('O1: no state at all', () async {
      final server = Server();
      await fails(
        server,
        backend(
          server,
          openBrowser: (url, redirect) async =>
              redirect.replace(queryParameters: {'code': 'c'}),
        ),
        "the redirect's state does not match the sign-in that opened it",
      );
    });

    test(
      'O2: the server answered with an error, with and without a description',
      () async {
        final server = Server();
        await fails(
          server,
          backend(
            server,
            openBrowser: browser(
              server,
              params: {
                'error': 'invalid_scope',
                'error_description': 'Invalid scopes: openid nonsense',
              },
            ),
          ),
          'the server answered the sign-in with error invalid_scope: Invalid scopes: openid nonsense',
        );
        await fails(
          server,
          backend(
            server,
            openBrowser: browser(server, params: {'error': 'login_required'}),
          ),
          'the server answered the sign-in with error login_required',
        );
      },
    );

    test('access_denied is the user giving up: AuthCancelled', () async {
      final server = Server();
      await expectLater(
        backend(
          server,
          openBrowser: browser(server, params: {'error': 'access_denied'}),
        ).signIn(signIn),
        throwsA(isA<AuthCancelled>()),
      );
    });

    test('O3: no code', () async {
      final server = Server();
      await fails(
        server,
        backend(server, openBrowser: browser(server, without: {'code'})),
        'the redirect has no code',
      );
      await fails(
        server,
        backend(server, openBrowser: browser(server, params: {'code': ''})),
        'the redirect has no code',
      );
    });

    test('O11: a redirect from another issuer (RFC 9207)', () async {
      final server = Server();
      await fails(
        server,
        backend(
          server,
          openBrowser: browser(
            server,
            params: {'iss': 'https://evil.example.org/realms/shop'},
          ),
        ),
        'the redirect comes from https://evil.example.org/realms/shop, not https://sso.example.com/realms/shop',
      );
    });

    test(
      'a redirect with no iss is accepted, and a trailing slash does not matter',
      () async {
        final server = Server();
        await backend(
          server,
          openBrowser: browser(server, without: {'iss'}),
        ).signIn(signIn);
        await backend(
          server,
          openBrowser: browser(server, params: {'iss': '$issuer/'}),
        ).signIn(signIn);
        expect(server.posts, hasLength(2));
      },
    );

    test(
      'the browser closing is AuthCancelled, thrown by openBrowser',
      () async {
        final oidc = backend(
          Server(),
          openBrowser: (_, _) async => throw const AuthCancelled(),
        );
        await expectLater(oidc.signIn(signIn), throwsA(isA<AuthCancelled>()));
      },
    );
  });

  group('the ID token', () {
    Future<void> fails(Server server, String message) => expectLater(
      backend(server).signIn(signIn),
      throwsA(
        isA<OidcException>().having((e) => e.message, 'message', message),
      ),
    );

    test(
      'O4: issued by another issuer, as when an emulator reaches Keycloak by 10.0.2.2',
      () async {
        final server = Server()
          ..idClaims = {'iss': 'http://localhost:8080/realms/shop'};
        await fails(
          server,
          'the ID token was issued by http://localhost:8080/realms/shop, not https://sso.example.com/realms/shop',
        );
      },
    );

    test('O5: for another client, as a string and as a list', () async {
      var server = Server()..idClaims = {'aud': 'other-app'};
      await fails(server, 'the ID token is for other-app, not for shop-app');
      server = Server()
        ..idClaims = {
          'aud': ['a', 'b'],
        };
      await fails(server, 'the ID token is for a, b, not for shop-app');
    });

    test('an audience list that has the client is fine', () async {
      final server = Server()
        ..idClaims = {
          'aud': ['account', clientId],
        };
      await backend(server).signIn(signIn);
    });

    test('O6: a nonce that is not the sign-in\'s', () async {
      final server = Server()..idClaims = {'nonce': 'replayed'};
      await fails(server, "the ID token's nonce does not match the sign-in");
    });

    test('an ID token that is not a JWT', () async {
      final server = Server()..extra = {'id_token': 'garbage'};
      await fails(server, 'the ID token is not a JWT');
    });

    test('tokens with no sub', () async {
      final server = Server()..idClaims = {'sub': null};
      await fails(server, 'the tokens carry no "sub" claim');
    });

    test('an answer with no access token', () async {
      final server = Server()..body = {'token_type': 'Bearer'};
      await fails(server, "the token endpoint's answer has no access_token");
    });
  });

  group('the session a sign-in makes', () {
    test(
      'the user, the roles of Keycloak, and the tokens against the clock',
      () async {
        final time = TestTime();
        await time.run(() async {
          final server = Server();
          final session = await backend(server).signIn(signIn);
          expect(session.backend, 'oidc');
          expect(session.user.id, 'u-1');
          expect(session.user.name, 'Ada Example');
          expect(session.user.email, 'ada@example.com');
          expect(session.user.roles, {'admin', 'offline_access', 'buyer'});
          expect(session.user.claims.keys, isNot(contains('jti')));
          expect(session.user.claims.keys, isNot(contains('nonce')));
          expect(session.tokens.tokenType, 'Bearer');
          expect(session.tokens.refreshToken, 'refresh-1');
          expect(
            session.tokens.expiresAt,
            time.now.add(const Duration(seconds: 300)),
          );
          expect(
            session.tokens.refreshExpiresAt,
            time.now.add(const Duration(seconds: 1800)),
          );
          expect(session.tokens.scope, 'openid profile email');
          expect(session.binding, isNull);
        });
      },
    );

    test('a refresh_expires_in of 0 never expires', () async {
      final server = Server()..extra = {'refresh_expires_in': 0};
      expect(
        (await backend(server).signIn(signIn)).tokens.refreshExpiresAt,
        isNull,
      );
    });

    test(
      'the exchange posts the code, the verifier and the client, as a form',
      () async {
        final server = Server();
        await backend(server).signIn(signIn);
        final post = server.posts.single;
        expect(post.url, endpoints.token);
        expect(
          post.headers['content-type'],
          startsWith('application/x-www-form-urlencoded'),
        );
        expect(post.headers['Accept'], 'application/json');
        expect(post.bodyFields, {
          'grant_type': 'authorization_code',
          'code': 'the-code',
          'redirect_uri': 'com.example.shop:/callback',
          'client_id': clientId,
          'code_verifier': post.bodyFields['code_verifier'],
        });
        expect(
          post.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('dpop')),
        );
      },
    );

    test(
      'O9: the token endpoint refusing the exchange says what it said',
      () async {
        final server = Server()
          ..status = 400
          ..body = {
            'error': 'invalid_grant',
            'error_description': 'Code not valid',
          };
        await expectLater(
          backend(server).signIn(signIn),
          throwsA(
            isA<OidcException>().having(
              (e) => e.message,
              'message',
              'the token endpoint answered HTTP 400: invalid_grant: Code not valid',
            ),
          ),
        );
        server
          ..body = 'oops'
          ..status = 502;
        await expectLater(
          backend(server).signIn(signIn),
          throwsA(
            isA<OidcException>().having(
              (e) => e.message,
              'message',
              'the token endpoint answered HTTP 502: no OAuth error in the answer',
            ),
          ),
        );
      },
    );

    test('no message carries a token, a code or a state', () async {
      final server = Server()
        ..status = 400
        ..body = {
          'error': 'invalid_grant',
          'error_description': 'Code not valid',
        };
      try {
        await backend(server).signIn(signIn);
      } on OidcException catch (e) {
        expect('$e', isNot(contains('the-code')));
        expect('$e', isNot(contains('refresh-')));
      }
    });
  });

  group('refresh', () {
    late Server server;
    late OidcBackend oidc;
    late AuthSession session;
    setUp(() async {
      server = Server();
      oidc = backend(server);
      session = await oidc.signIn(signIn);
      server.requests.clear();
    });

    test('posts the refresh token and the client, and rotates', () async {
      final next = await oidc.refresh(session);
      final post = server.posts.single;
      expect(post.bodyFields, {
        'grant_type': 'refresh_token',
        'refresh_token': 'refresh-1',
        'client_id': clientId,
      });
      expect(next.tokens.accessToken, isNot(session.tokens.accessToken));
      expect(next.tokens.refreshToken, 'refresh-2');
      expect(
        next.user,
        session.user,
        reason: 'the same user: nothing notifies authUser',
      );
    });

    test(
      'a response that leaves out the refresh token and the ID token keeps the old ones',
      () async {
        server.answer = (_) {
          final response = server.tokenResponse()
            ..remove('refresh_token')
            ..remove('id_token')
            ..remove('refresh_expires_in');
          return response;
        };
        final next = await oidc.refresh(session);
        expect(next.tokens.refreshToken, 'refresh-1');
        expect(next.tokens.idToken, session.tokens.idToken);
        expect(next.tokens.refreshExpiresAt, session.tokens.refreshExpiresAt);
        expect(next.user, session.user);
        expect(next.tokens.accessToken, isNot(session.tokens.accessToken));
      },
    );

    test('a new ID token replaces the user, with its roles', () async {
      server.answer = (_) {
        server.accessClaims = {
          'realm_access': {
            'roles': ['staff'],
          },
          'resource_access': <String, Object?>{},
        };
        server.idClaims = {'name': 'Ada L.'};
        return server.tokenResponse();
      };
      final next = await oidc.refresh(session);
      expect(next.user.name, 'Ada L.');
      expect(next.user.roles, {
        'staff',
      }, reason: 'read from the new access token');
    });

    test('a new ID token is checked too: another issuer is refused', () async {
      server.idClaims = {'iss': 'https://evil.example.org/realms/shop'};
      await expectLater(oidc.refresh(session), throwsA(isA<OidcException>()));
    });

    for (final (error, description) in const [
      ('invalid_grant', 'Token is not active'),
      ('invalid_grant', 'Session not active'),
      ('invalid_grant', 'Maximum allowed refresh token reuse exceeded'),
      ('invalid_grant', "Session doesn't have required client"),
      ('invalid_grant', 'Invalid refresh token'),
      ('invalid_client', 'Invalid client or Invalid client credentials'),
      ('unauthorized_client', null),
    ]) {
      test('$error ($description) ends the session: AuthRejected', () async {
        server
          ..status = error == 'invalid_client' ? 401 : 400
          ..body = {'error': error, 'error_description': ?description};
        await expectLater(
          oidc.refresh(session),
          throwsA(
            isA<AuthRejected>()
                .having((e) => e.error, 'error', error)
                .having((e) => e.description, 'description', description),
          ),
        );
      });
    }

    test(
      'a 503 is unavailable, and so is a socket error: the session stays',
      () async {
        server
          ..status = 503
          ..body = 'down';
        await expectLater(
          oidc.refresh(session),
          throwsA(isA<AuthUnavailable>()),
        );
        final broken = OidcBackend(
          issuer: issuer,
          clientId: clientId,
          redirectUri: redirectUri,
          openBrowser: browser(server),
          endpoints: endpoints,
          client: MockClient(
            (_) async => throw http.ClientException('Connection refused'),
          ),
        );
        await expectLater(
          broken.refresh(session),
          throwsA(
            isA<AuthUnavailable>().having(
              (e) => e.message,
              'message',
              contains('Connection refused'),
            ),
          ),
        );
      },
    );

    test(
      'an invalid_request (a DPoP proof that is not active) is not the end of the session',
      () async {
        server
          ..status = 400
          ..body = {
            'error': 'invalid_request',
            'error_description': 'DPoP proof is not active',
          };
        await expectLater(
          oidc.refresh(session),
          throwsA(
            isA<OidcException>().having(
              (e) => e.message,
              'message',
              'the token endpoint answered HTTP 400: invalid_request: DPoP proof is not active',
            ),
          ),
        );
      },
    );

    test('a session with no refresh token is over', () async {
      final bare = session.copyWith(tokens: const AuthTokens(accessToken: 'a'));
      await expectLater(
        oidc.refresh(bare),
        throwsA(
          isA<AuthRejected>().having(
            (e) => e.toString(),
            'toString',
            'AuthRejected: the server refused the session '
                '(invalid_grant: there is no refresh token)',
          ),
        ),
      );
    });
  });

  group('signOut and endBrowserSession', () {
    test(
      'revokes the refresh token (RFC 7009), at the revocation endpoint',
      () async {
        final server = Server();
        final oidc = backend(server);
        final session = await oidc.signIn(signIn);
        server.requests.clear();
        await oidc.signOut(session);
        final post = server.posts.single;
        expect(post.url, endpoints.revocation);
        expect(post.bodyFields, {
          'token': 'refresh-1',
          'token_type_hint': 'refresh_token',
          'client_id': clientId,
        });
      },
    );

    test('with no refresh token or no endpoint it asks for nothing', () async {
      final server = Server();
      final oidc = backend(server);
      final session = await oidc.signIn(signIn);
      server.requests.clear();
      await oidc.signOut(
        session.copyWith(tokens: const AuthTokens(accessToken: 'a')),
      );
      await backend(
        server,
        known: OidcEndpoints(
          authorization: endpoints.authorization,
          token: endpoints.token,
        ),
      ).signOut(session);
      expect(server.requests, isEmpty);
    });

    test(
      'a failing revocation is thrown, for the notifier to swallow',
      () async {
        final server = Server();
        final oidc = backend(server);
        final session = await oidc.signIn(signIn);
        final failing = OidcBackend(
          issuer: issuer,
          clientId: clientId,
          redirectUri: redirectUri,
          openBrowser: browser(server),
          endpoints: endpoints,
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );
        await expectLater(
          failing.signOut(session),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test(
      'endBrowserSession opens the end-session URL with the hint and the post-logout redirect',
      () async {
        final server = Server();
        final session = await backend(server).signIn(signIn);
        final opened = <Uri>[];
        final oidc = OidcBackend(
          issuer: issuer,
          clientId: clientId,
          redirectUri: redirectUri,
          postLogoutRedirectUri: Uri.parse('com.example.shop:/logout'),
          openBrowser: (url, back) async {
            opened.add(url);
            expect(back, Uri.parse('com.example.shop:/logout'));
            return back;
          },
          endpoints: endpoints,
          client: server.client,
        );
        await oidc.endBrowserSession(session);
        final p = opened.single.queryParameters;
        expect(
          opened.single.path,
          '/realms/shop/protocol/openid-connect/logout',
        );
        expect(p['id_token_hint'], session.tokens.idToken);
        expect(p['client_id'], clientId);
        expect(p['post_logout_redirect_uri'], 'com.example.shop:/logout');
      },
    );

    test('a closed browser is not an error', () async {
      final server = Server();
      final session = await backend(server).signIn(signIn);
      final oidc = backend(
        server,
        openBrowser: (_, _) async => throw const AuthCancelled(),
      );
      await oidc.endBrowserSession(session);
    });
  });

  group('endpoints', () {
    test(
      'keycloak() spells the four endpoints of the realm, with no request',
      () {
        final e = OidcEndpoints.keycloak(
          Uri.parse('https://sso.example.com/realms/shop/'),
        );
        expect(
          e.authorization.toString(),
          'https://sso.example.com/realms/shop/protocol/openid-connect/auth',
        );
        expect(
          e.token.toString(),
          'https://sso.example.com/realms/shop/protocol/openid-connect/token',
        );
        expect(
          e.revocation.toString(),
          'https://sso.example.com/realms/shop/protocol/openid-connect/revoke',
        );
        expect(
          e.endSession.toString(),
          'https://sso.example.com/realms/shop/protocol/openid-connect/logout',
        );
      },
    );

    test('discovery is lazy, runs once, and is kept', () async {
      final server = Server();
      final oidc = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
        openBrowser: browser(server),
        client: server.client,
        random: Random(1),
      );
      expect(server.requests, isEmpty);
      final session = await oidc.signIn(signIn);
      await oidc.refresh(session);
      await oidc.refresh(session);
      expect(server.requests.where((r) => r.method == 'GET'), hasLength(1));
      expect(
        server.requests.first.url.toString(),
        'https://sso.example.com/realms/shop/.well-known/openid-configuration',
      );
    });

    test('concurrent first uses share one discovery', () async {
      final server = Server();
      final oidc = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
        openBrowser: browser(server),
        client: server.client,
        random: Random(1),
      );
      final session = fakeSession(ada, backend: 'oidc');
      await Future.wait([
        oidc.refresh(
          session.copyWith(
            tokens: const AuthTokens(accessToken: 'a', refreshToken: 'r'),
          ),
        ),
        oidc.refresh(
          session.copyWith(
            tokens: const AuthTokens(accessToken: 'a', refreshToken: 'r'),
          ),
        ),
      ]);
      expect(server.requests.where((r) => r.method == 'GET'), hasLength(1));
    });

    test('O7: discovery failing, and a failure is not remembered', () async {
      var up = false;
      final client = MockClient((request) async {
        if (!up) return http.Response('nope', 503);
        return http.Response(
          jsonEncode({
            'issuer': issuer.toString(),
            'authorization_endpoint': endpoints.authorization.toString(),
            'token_endpoint': endpoints.token.toString(),
          }),
          200,
        );
      });
      final server = Server();
      final oidc = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
        openBrowser: browser(server),
        client: client,
      );
      await expectLater(
        oidc.signIn(signIn),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            'discovery at https://sso.example.com/realms/shop/.well-known/openid-configuration failed with HTTP 503',
          ),
        ),
      );
      up = true;
      // Found now (the token endpoint then answers on the mock: not under test here).
      expect(
        await OidcEndpoints.discover(issuer, client: client),
        isA<OidcEndpoints>(),
      );
    });

    test('O8: the document of another issuer is refused', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'issuer': 'https://evil.example.org/realms/shop',
            'authorization_endpoint': 'https://evil.example.org/auth',
            'token_endpoint': 'https://evil.example.org/token',
          }),
          200,
        ),
      );
      await expectLater(
        OidcEndpoints.discover(issuer, client: client),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            "the discovery document's issuer https://evil.example.org/realms/shop is not https://sso.example.com/realms/shop",
          ),
        ),
      );
    });

    test('a discovery document that is not usable is refused', () async {
      const url =
          'https://sso.example.com/realms/shop/.well-known/openid-configuration';
      for (final (body, message) in [
        ('not json', 'discovery at $url did not answer JSON'),
        ('[]', 'discovery at $url did not answer a JSON object'),
        (
          '{"issuer": "https://sso.example.com/realms/shop"}',
          'discovery at $url has no authorization_endpoint or token_endpoint',
        ),
      ]) {
        final client = MockClient((_) async => http.Response(body, 200));
        await expectLater(
          OidcEndpoints.discover(issuer, client: client),
          throwsA(
            isA<OidcException>().having((e) => e.message, 'message', message),
          ),
          reason: body,
        );
      }
    });

    test('O10: a server that does not take ES256 proofs', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'issuer': issuer.toString(),
            'authorization_endpoint': endpoints.authorization.toString(),
            'token_endpoint': endpoints.token.toString(),
            'dpop_signing_alg_values_supported': ['RS256', 'PS256'],
          }),
          200,
        ),
      );
      final oidc = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
        openBrowser: browser(Server()),
        client: client,
        proof: FakeProof(),
      );
      await expectLater(
        oidc.signIn(signIn),
        throwsA(
          isA<OidcException>().having(
            (e) => e.message,
            'message',
            'the server does not accept ES256 DPoP proofs (dpop_signing_alg_values_supported: RS256, PS256)',
          ),
        ),
      );
    });

    test('a server that lists no algorithms is taken at its word', () async {
      final server = Server();
      await backend(server, proof: FakeProof()).signIn(signIn);
    });
  });

  group('keycloakRoles', () {
    test(
      'reads realm roles and the roles of the app\'s own client, from either token',
      () {
        final roles = keycloakRoles('shop-app');
        expect(
          roles(
            {
              'realm_access': {
                'roles': ['admin'],
              },
              'resource_access': {
                'shop-app': {
                  'roles': ['buyer'],
                },
                'account': {
                  'roles': ['manage-account'],
                },
              },
            },
            {
              'realm_access': {
                'roles': ['staff'],
              },
            },
          ),
          {'admin', 'buyer', 'staff'},
        );
      },
    );

    test('is empty for tokens that carry none, or carry them badly', () {
      final roles = keycloakRoles('shop-app');
      expect(roles({}, {}), isEmpty);
      expect(
        roles(
          {'realm_access': 'x', 'resource_access': []},
          {
            'realm_access': {'roles': 'admin'},
          },
        ),
        isEmpty,
      );
      expect(
        roles({
          'realm_access': {
            'roles': ['a', 1, null],
          },
        }, {}),
        {'a'},
      );
    });
  });

  group('DPoP', () {
    test(
      'dpop_jkt binds the code to the key, and the exchange carries a proof (no ath)',
      () async {
        final proof = FakeProof(thumbprintValue: 'device-key');
        final server = Server();
        final opened = <Uri>[];
        final oidc = backend(
          server,
          proof: proof,
          openBrowser: browser(server, opened: opened),
        );
        server.extra = {'token_type': 'DPoP'};
        final session = await oidc.signIn(signIn);
        expect(opened.single.queryParameters['dpop_jkt'], 'device-key');
        final post = server.posts.single;
        expect(
          post.headers['DPoP'],
          'fake-proof-1 POST https://sso.example.com/realms/shop/protocol/openid-connect/token',
        );
        expect(session.tokens.isDpop, isTrue);
        expect(session.binding, 'device-key');
      },
    );

    test('bindCodeToKey: false leaves dpop_jkt out', () async {
      final server = Server();
      final opened = <Uri>[];
      await backend(
        server,
        proof: FakeProof(),
        bindCodeToKey: false,
        openBrowser: browser(server, opened: opened),
      ).signIn(signIn);
      expect(opened.single.queryParameters.keys, isNot(contains('dpop_jkt')));
    });

    test(
      'a bearer token (a provider that binds only the refresh token) has no binding',
      () async {
        final server = Server();
        final session = await backend(
          server,
          proof: FakeProof(),
        ).signIn(signIn);
        expect(session.tokens.isDpop, isFalse);
        expect(session.binding, isNull);
      },
    );

    test(
      'a nonce challenge at the token endpoint is answered once, with a fresh proof',
      () async {
        final proof = FakeProof()..challengeNext = true;
        final server = Server();
        server.extra = {'token_type': 'DPoP'};
        await backend(server, proof: proof).signIn(signIn);
        expect(server.posts, hasLength(2));
        expect(
          server.posts[0].headers['DPoP'],
          isNot(server.posts[1].headers['DPoP']),
        );
        expect(server.posts[1].headers['DPoP'], endsWith('nonce=nonce-1'));
        expect(proof.proofs, hasLength(2));
      },
    );

    test('a refresh carries a proof of the same key', () async {
      final proof = FakeProof(thumbprintValue: 'device-key');
      final server = Server()..extra = {'token_type': 'DPoP'};
      final oidc = backend(server, proof: proof);
      final session = await oidc.signIn(signIn);
      server.requests.clear();
      final next = await oidc.refresh(session);
      expect(
        server.posts.single.headers['DPoP'],
        startsWith('fake-proof-2 POST '),
      );
      expect(next.binding, 'device-key');
    });

    test(
      'invalid_dpop_proof and use_dpop_nonce, after the one retry, end the session',
      () async {
        final proof = FakeProof();
        final server = Server()..extra = {'token_type': 'DPoP'};
        final oidc = backend(server, proof: proof);
        final session = await oidc.signIn(signIn);
        for (final error in ['invalid_dpop_proof', 'use_dpop_nonce']) {
          server
            ..status = 400
            ..body = {'error': error};
          await expectLater(
            oidc.refresh(session),
            throwsA(isA<AuthRejected>().having((e) => e.error, 'error', error)),
          );
        }
      },
    );
  });
}
