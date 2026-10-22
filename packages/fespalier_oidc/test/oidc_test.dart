// OidcBackend on a FakeTransport that plays the provider: the authorization URL, PKCE, every check
// of the redirect and of the ID token, the code exchange, renewal with rotation, the errors and
// what DPoP adds.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_oidc/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_provider.dart';
import 'support.dart';

const signIn = BrowserSignIn();

void main() {
  group('the backend', () {
    test('names itself, its scheme and the way its credential is read', () {
      final server = Server();
      final bearer = backend(server);
      expect(bearer.name, 'oidc');
      expect(bearer.scheme, 'bearer');
      expect(bearer.renewAhead, const Duration(seconds: 30));
      expect(bearer.authenticator, isA<BearerAuthenticator>());
      expect(bearer.authenticator.proof, isNull);
      expect(bearer.keepsOwnSession, isFalse);

      final proof = FakeProof();
      final dpop = backend(server, proof: proof);
      expect(dpop.scheme, 'dpop');
      expect(dpop.authenticator.proof, same(proof));
    });

    test('renewAhead is the backend\'s own, not a global leeway', () {
      final oidc = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
        openBrowser: browser(Server()),
        transport: Server().transport,
        renewAhead: const Duration(minutes: 2),
      );
      expect(oidc.renewAhead, const Duration(minutes: 2));
    });

    test('readCredential reads what a TokenCredential wrote, and no other', () {
      final oidc = backend(Server());
      final tokens = TokenCredential(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.utc(2026, 3, 1),
        jkt: 'k',
      );
      expect(oidc.readCredential(tokens.toJson()), tokens);
      expect(
        () => oidc.readCredential(<String, Object?>{'id': 'fake-1'}),
        throwsFormatException,
      );
    });
  });

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

    test('the redirect URI handed to the browser is the backend\'s', () async {
      final server = Server();
      Uri? given;
      await backend(
        server,
        openBrowser: (url, redirect) {
          given = redirect;
          return browser(server)(url, redirect);
        },
      ).signIn(signIn);
      expect(given, redirectUri);
    });

    test('only a BrowserSignIn: anything else is an UnsupportedError', () async {
      final backend0 = backend(Server());
      await expectLater(
        backend0.signIn(const PasswordSignIn(username: 'a', password: 'b')),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            'fespalier_oidc: OidcBackend signs in with BrowserSignIn, not PasswordSignIn',
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
      expect(server.posts, isEmpty, reason: 'no code is exchanged');
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
          final tokens = tokensOf(session);
          expect(session.backend, 'oidc');
          expect(session.user.id, 'u-1');
          expect(session.user.name, 'Ada Example');
          expect(session.user.email, 'ada@example.com');
          expect(session.user.roles, {'admin', 'offline_access', 'buyer'});
          expect(session.user.claims.keys, isNot(contains('jti')));
          expect(session.user.claims.keys, isNot(contains('nonce')));
          expect(tokens.tokenType, 'Bearer');
          expect(tokens.refreshToken, 'refresh-1');
          expect(tokens.expiresAt, time.now.add(const Duration(seconds: 300)));
          expect(
            tokens.refreshExpiresAt,
            time.now.add(const Duration(seconds: 1800)),
          );
          expect(tokens.renewableUntil, tokens.refreshExpiresAt);
          expect(tokens.renewable, isTrue);
          expect(tokens.scope, 'openid profile email');
          expect(tokens.jkt, isNull);
        });
      },
    );

    test('a refresh_expires_in of 0 never expires', () async {
      final server = Server()..extra = {'refresh_expires_in': 0};
      final tokens = tokensOf(await backend(server).signIn(signIn));
      expect(tokens.refreshExpiresAt, isNull);
      expect(tokens.renewableUntil, isNull);
    });

    test(
      'an answer with no expires_in has an access token that never expires',
      () async {
        final server = Server();
        server.answer = (_) => server.tokenResponse()..remove('expires_in');
        expect(
          tokensOf(await backend(server).signIn(signIn)).expiresAt,
          isNull,
        );
      },
    );

    test(
      'the exchange posts the code, the verifier and the client, as a form',
      () async {
        final server = Server();
        await backend(server).signIn(signIn);
        final post = server.posts.single;
        expect(post.url, endpoints.token);
        expect(
          post.header('content-type'),
          'application/x-www-form-urlencoded; charset=utf-8',
        );
        expect(post.header('accept'), 'application/json');
        expect(post.bodyFields, {
          'grant_type': 'authorization_code',
          'code': 'the-code',
          'redirect_uri': 'com.example.shop:/callback',
          'client_id': clientId,
          'code_verifier': post.bodyFields['code_verifier'],
        });
        expect(post.lowerHeaders.keys, isNot(contains('dpop')));
        expect(
          post.lowerHeaders.keys,
          isNot(contains('authorization')),
          reason: 'the token endpoint is not the API: no session is attached',
        );
      },
    );

    test('the body is the exact form bytes, percent-encoded', () async {
      final server = Server();
      await backend(server).signIn(signIn);
      final bytes = server.posts.single.body;
      // `redirect_uri=com.example.shop%3A%2Fcallback`: the colon and the slash are escaped.
      expect(
        utf8.decode(bytes),
        contains('redirect_uri=com.example.shop%3A%2Fcallback'),
      );
      expect(server.posts.single.request.bodyStream, isNull);
    });

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
      Object? thrown;
      try {
        await backend(server).signIn(signIn);
      } on OidcException catch (e) {
        thrown = e;
      }
      expect(thrown, isA<OidcException>());
      expect('$thrown', isNot(contains('the-code')));
      expect('$thrown', isNot(contains('refresh-')));
    });

    test('a transport failure at the exchange is thrown as it is', () async {
      final server = Server();
      final oidc = backend(
        server,
        transport: FakeTransport(
          (_, _) => throw const TransportUnsent('Connection refused'),
        ),
      );
      await expectLater(oidc.signIn(signIn), throwsA(isA<TransportUnsent>()));
    });
  });

  group('renew', () {
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
      final next = await oidc.renew(session);
      final post = server.posts.single;
      expect(post.url, endpoints.token);
      expect(post.bodyFields, {
        'grant_type': 'refresh_token',
        'refresh_token': 'refresh-1',
        'client_id': clientId,
      });
      expect(tokensOf(next).accessToken, isNot(tokensOf(session).accessToken));
      expect(tokensOf(next).refreshToken, 'refresh-2');
      expect(
        next.user,
        session.user,
        reason: 'the same user: nothing notifies authUser',
      );
    });

    test('the hint is not used', () async {
      final next = await oidc.renew(session, hint: 'some-key-role');
      expect(tokensOf(next).refreshToken, 'refresh-2');
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
        final next = await oidc.renew(session);
        expect(tokensOf(next).refreshToken, 'refresh-1');
        expect(tokensOf(next).idToken, tokensOf(session).idToken);
        expect(
          tokensOf(next).refreshExpiresAt,
          tokensOf(session).refreshExpiresAt,
        );
        expect(next.user, session.user);
        expect(
          tokensOf(next).accessToken,
          isNot(tokensOf(session).accessToken),
        );
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
      final next = await oidc.renew(session);
      expect(next.user.name, 'Ada L.');
      expect(next.user.roles, {
        'staff',
      }, reason: 'read from the new access token');
    });

    test('a new ID token is checked too: another issuer is refused', () async {
      server.idClaims = {'iss': 'https://evil.example.org/realms/shop'};
      await expectLater(oidc.renew(session), throwsA(isA<OidcException>()));
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
          oidc.renew(session),
          throwsA(
            isA<AuthRejected>()
                .having((e) => e.error, 'error', error)
                .having((e) => e.description, 'description', description),
          ),
        );
      });
    }

    test('a 503 is unavailable, and the session stays', () async {
      server
        ..status = 503
        ..body = 'down';
      await expectLater(
        oidc.renew(session),
        throwsA(
          isA<AuthUnavailable>().having(
            (e) => e.cause,
            'cause',
            isA<OidcException>().having(
              (e) => e.message,
              'message',
              'the token endpoint answered HTTP 503: no OAuth error in the answer',
            ),
          ),
        ),
      );
    });

    test('a transport failure is unavailable too, and names no host', () async {
      final broken = backend(
        server,
        transport: FakeTransport(
          (_, _) => throw const TransportUnsent('Connection refused'),
        ),
      );
      await expectLater(
        broken.renew(session),
        throwsA(
          isA<AuthUnavailable>()
              .having(
                (e) => e.cause,
                'cause',
                isA<TransportUnsent>().having(
                  (e) => e.cause,
                  'cause',
                  'Connection refused',
                ),
              )
              .having((e) => '$e', 'text', isNot(contains('sso.example.com'))),
        ),
      );
    });

    test('a timeout and a broken exchange are unavailable', () async {
      for (final failure in const <TransportFailure>[
        TransportTimedOut(),
        TransportBroken(),
      ]) {
        final broken = backend(
          server,
          transport: FakeTransport((_, _) => throw failure),
        );
        await expectLater(
          broken.renew(session),
          throwsA(
            isA<AuthUnavailable>().having((e) => e.cause, 'cause', failure),
          ),
        );
      }
    });

    test(
      'a discovery that cannot run is unavailable; one that is refused is an OidcException',
      () async {
        final down = discovering(server);
        server.discoveryStatus = 503;
        await expectLater(
          down.renew(session),
          throwsA(isA<OidcException>()),
          reason: 'a discovery error is not about the session',
        );
        final offline = OidcBackend(
          issuer: issuer,
          clientId: clientId,
          redirectUri: redirectUri,
          openBrowser: browser(server),
          transport: FakeTransport((_, _) => throw const TransportBroken()),
        );
        await expectLater(
          offline.renew(session),
          throwsA(isA<AuthUnavailable>()),
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
          oidc.renew(session),
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
      final bare = session.copyWith(
        credential: const TokenCredential(accessToken: 'a'),
      );
      await expectLater(
        oidc.renew(bare),
        throwsA(
          isA<AuthRejected>().having(
            (e) => e.toString(),
            'toString',
            'AuthRejected: the server refused the session '
                '(invalid_grant: there is no refresh token)',
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('a session of another scheme\'s credential is a StateError', () async {
      final foreign = AuthSession(
        backend: 'oidc',
        credential: const _OtherCredential(),
        user: ada,
      );
      await expectLater(oidc.renew(foreign), throwsStateError);
      expect(server.requests, isEmpty);
    });
  });

  group('check and discard', () {
    AuthSession bound(String? jkt) => AuthSession(
      backend: 'oidc',
      credential: TokenCredential(
        accessToken: 'a',
        tokenType: jkt == null ? 'Bearer' : 'DPoP',
        refreshToken: 'r',
        jkt: jkt,
      ),
      user: ada,
    );

    test('a session that is not bound to a key is kept', () async {
      expect(await backend(Server()).check(bound(null)), isNull);
      expect(
        await backend(Server(), proof: FakeProof()).check(bound(null)),
        isNull,
      );
    });

    test('a bound session on the same key is kept', () async {
      final oidc = backend(
        Server(),
        proof: FakeProof(thumbprintValue: 'this-device'),
      );
      expect(await oidc.check(bound('this-device')), isNull);
    });

    test(
      'a bound session on another key, or on no proof, is keyLost',
      () async {
        final other = backend(
          Server(),
          proof: FakeProof(thumbprintValue: 'another-device'),
        );
        expect(await other.check(bound('this-device')), SignOutReason.keyLost);
        expect(
          await backend(Server()).check(bound('this-device')),
          SignOutReason.keyLost,
        );
      },
    );

    test('discard resets the proof, and is a no-op without one', () async {
      final proof = FakeProof();
      await backend(Server(), proof: proof).discard(bound(null));
      expect(proof.resets, 1);
      await backend(Server()).discard(bound(null));
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
        expect(
          post.header('content-type'),
          'application/x-www-form-urlencoded; charset=utf-8',
        );
      },
    );

    test('with no refresh token or no endpoint it asks for nothing', () async {
      final server = Server();
      final oidc = backend(server);
      final session = await oidc.signIn(signIn);
      server.requests.clear();
      await oidc.signOut(
        session.copyWith(credential: const TokenCredential(accessToken: 'a')),
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
        final failing = backend(
          server,
          transport: FakeTransport((_, _) => throw const TransportBroken()),
        );
        await expectLater(
          failing.signOut(session),
          throwsA(isA<TransportBroken>()),
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
          transport: server.transport,
        );
        await oidc.endBrowserSession(session);
        final p = opened.single.queryParameters;
        expect(
          opened.single.path,
          '/realms/shop/protocol/openid-connect/logout',
        );
        expect(p['id_token_hint'], tokensOf(session).idToken);
        expect(p['client_id'], clientId);
        expect(p['post_logout_redirect_uri'], 'com.example.shop:/logout');
      },
    );

    test(
      'without a post-logout redirect it falls back to the redirect URI',
      () async {
        final server = Server();
        final session = await backend(server).signIn(signIn);
        Uri? back;
        final oidc = backend(
          server,
          openBrowser: (url, redirect) async {
            back = redirect;
            return redirect;
          },
        );
        await oidc.endBrowserSession(session);
        expect(back, redirectUri);
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
      final oidc = discovering(server);
      expect(server.requests, isEmpty);
      final session = await oidc.signIn(signIn);
      await oidc.renew(session);
      await oidc.renew(session);
      expect(server.gets, hasLength(1));
      expect(
        server.gets.single.url.toString(),
        'https://sso.example.com/realms/shop/.well-known/openid-configuration',
      );
      expect(server.gets.single.header('accept'), 'application/json');
    });

    test('concurrent first uses share one discovery', () async {
      final server = Server();
      final oidc = discovering(server);
      final session = fakeTokenSession(ada);
      await Future.wait([oidc.renew(session), oidc.renew(session)]);
      expect(server.gets, hasLength(1));
    });

    test('O7: discovery failing, and a failure is not remembered', () async {
      final server = Server()..discoveryStatus = 503;
      final oidc = discovering(server);
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
      server.discoveryStatus = 200;
      final session = await oidc.signIn(signIn);
      expect(session.user.id, 'u-1');
      expect(server.gets, hasLength(2), reason: 'asked again, then kept');
    });

    test('O8: the document of another issuer is refused', () async {
      final server = Server()
        ..discovery = {
          'issuer': 'https://evil.example.org/realms/shop',
          'authorization_endpoint': 'https://evil.example.org/auth',
          'token_endpoint': 'https://evil.example.org/token',
        };
      await expectLater(
        OidcEndpoints.discover(issuer, transport: server.transport),
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
        final server = Server()..discovery = body;
        await expectLater(
          OidcEndpoints.discover(issuer, transport: server.transport),
          throwsA(
            isA<OidcException>().having((e) => e.message, 'message', message),
          ),
          reason: body,
        );
      }
    });

    test(
      'the document of the issuer gives all four endpoints and the algs',
      () async {
        final found = await OidcEndpoints.discover(
          issuer,
          transport: Server().transport,
        );
        expect(found.authorization, endpoints.authorization);
        expect(found.token, endpoints.token);
        expect(found.revocation, endpoints.revocation);
        expect(found.endSession, endpoints.endSession);
        expect(found.dpopAlgorithms, ['ES256', 'RS256']);
      },
    );

    test('O10: a server that does not take ES256 proofs', () async {
      final server = Server()
        ..discovery = {
          'issuer': issuer.toString(),
          'authorization_endpoint': endpoints.authorization.toString(),
          'token_endpoint': endpoints.token.toString(),
          'dpop_signing_alg_values_supported': ['RS256', 'PS256'],
        };
      final oidc = discovering(server, proof: FakeProof());
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
      final server = Server()
        ..discovery = {
          'issuer': issuer.toString(),
          'authorization_endpoint': endpoints.authorization.toString(),
          'token_endpoint': endpoints.token.toString(),
        };
      await discovering(server, proof: FakeProof()).signIn(signIn);
    });

    test('a bearer backend does not mind the algorithms', () async {
      final server = Server()
        ..discovery = {
          'issuer': issuer.toString(),
          'authorization_endpoint': endpoints.authorization.toString(),
          'token_endpoint': endpoints.token.toString(),
          'dpop_signing_alg_values_supported': ['RS256'],
        };
      await discovering(server).signIn(signIn);
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

    test('a custom roles reader replaces the Keycloak one', () async {
      final server = Server();
      final oidc = OidcBackend(
        issuer: issuer,
        clientId: clientId,
        redirectUri: redirectUri,
        openBrowser: browser(server),
        endpoints: endpoints,
        transport: server.transport,
        roles: (access, id) => {'from-id-${id['sub']}'},
      );
      expect((await oidc.signIn(signIn)).user.roles, {'from-id-u-1'});
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
          post.header('DPoP'),
          'fake-proof-1 POST https://sso.example.com/realms/shop/protocol/openid-connect/token',
        );
        expect(tokensOf(session).isDpop, isTrue);
        expect(tokensOf(session).jkt, 'device-key');
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
      'a bearer token (a provider that binds only the refresh token) is not bound',
      () async {
        final server = Server();
        final session = await backend(
          server,
          proof: FakeProof(),
        ).signIn(signIn);
        expect(tokensOf(session).isDpop, isFalse);
        expect(tokensOf(session).jkt, isNull);
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
          server.posts[0].header('DPoP'),
          isNot(server.posts[1].header('DPoP')),
        );
        expect(server.posts[1].header('DPoP'), endsWith('nonce=nonce-1'));
        expect(proof.proofs, hasLength(2));
        expect(
          server.posts[0].body,
          server.posts[1].body,
          reason: 'the same form, the code survives the retry',
        );
      },
    );

    test('a nonce the token endpoint sends is used by the next call', () async {
      final proof = FakeProof();
      final server = Server()
        ..extra = {'token_type': 'DPoP'}
        ..tokenHeaders = {'DPoP-Nonce': 'abc'};
      final oidc = backend(server, proof: proof);
      final session = await oidc.signIn(signIn);
      server.requests.clear();
      await oidc.renew(session);
      expect(server.posts.single.header('DPoP'), endsWith('nonce=abc'));
    });

    test('a renewal carries a proof of the same key', () async {
      final proof = FakeProof(thumbprintValue: 'device-key');
      final server = Server()..extra = {'token_type': 'DPoP'};
      final oidc = backend(server, proof: proof);
      final session = await oidc.signIn(signIn);
      server.requests.clear();
      final next = await oidc.renew(session);
      expect(
        server.posts.single.header('DPoP'),
        startsWith('fake-proof-2 POST '),
      );
      expect(tokensOf(next).jkt, 'device-key');
    });

    test('a revocation carries a proof too', () async {
      final proof = FakeProof();
      final server = Server()..extra = {'token_type': 'DPoP'};
      final oidc = backend(server, proof: proof);
      final session = await oidc.signIn(signIn);
      server.requests.clear();
      await oidc.signOut(session);
      expect(
        server.posts.single.header('DPoP'),
        startsWith('fake-proof-2 POST '),
      );
      expect(server.posts.single.url, endpoints.revocation);
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
            oidc.renew(session),
            throwsA(isA<AuthRejected>().having((e) => e.error, 'error', error)),
          );
        }
      },
    );
  });
}

/// A credential that is not a token: a session that another backend made.
final class _OtherCredential implements SessionCredential {
  const _OtherCredential();

  @override
  DateTime? get expiresAt => null;

  @override
  DateTime? get renewableUntil => null;

  @override
  bool get renewable => true;

  @override
  Map<String, Object?> toJson() => const <String, Object?>{};
}
