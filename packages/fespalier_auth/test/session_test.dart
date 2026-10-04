// The values a session is made of: JSON round trips, equality, and what `toString` never shows.
import 'dart:convert';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final expires = DateTime.utc(2026, 3, 1, 12, 5);
  final tokens = AuthTokens(
    accessToken: 'access-secret',
    tokenType: 'DPoP',
    refreshToken: 'refresh-secret',
    idToken: 'id-secret',
    expiresAt: expires,
    refreshExpiresAt: DateTime.utc(2026, 3, 1, 12, 30),
    scope: 'openid email',
  );

  group('AuthTokens', () {
    test('survive a JSON round trip, dates in UTC', () {
      final back = AuthTokens.fromJson(
        jsonDecode(jsonEncode(tokens.toJson())) as Map<String, Object?>,
      );
      expect(back, tokens);
      expect(back.hashCode, tokens.hashCode);
      expect(back.expiresAt!.isUtc, isTrue);
    });

    test('a token type is Bearer unless the response said otherwise', () {
      expect(const AuthTokens(accessToken: 'a').tokenType, 'Bearer');
      expect(const AuthTokens(accessToken: 'a').isDpop, isFalse);
      expect(tokens.isDpop, isTrue);
      expect(
        const AuthTokens(accessToken: 'a', tokenType: 'dpop').isDpop,
        isTrue,
      );
    });

    test('expiry counts the leeway early, and unknown never expires', () {
      expect(
        tokens.isExpiredAt(expires.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(tokens.isExpiredAt(expires), isTrue);
      expect(
        tokens.isExpiredAt(
          expires.subtract(const Duration(seconds: 29)),
          leeway: const Duration(seconds: 30),
        ),
        isTrue,
      );
      expect(
        tokens.isExpiredAt(
          expires.subtract(const Duration(seconds: 31)),
          leeway: const Duration(seconds: 30),
        ),
        isFalse,
      );
      expect(const AuthTokens(accessToken: 'a').isExpiredAt(expires), isFalse);
    });

    test('merge keeps the refresh and ID tokens a response left out', () {
      final refreshed = AuthTokens(
        accessToken: 'new-access',
        tokenType: 'DPoP',
        expiresAt: expires.add(const Duration(minutes: 5)),
      );
      final merged = tokens.merge(refreshed);
      expect(merged.accessToken, 'new-access');
      expect(merged.refreshToken, 'refresh-secret');
      expect(merged.idToken, 'id-secret');
      expect(merged.refreshExpiresAt, tokens.refreshExpiresAt);
      expect(merged.scope, 'openid email');
      expect(merged.expiresAt, refreshed.expiresAt);
    });

    test('merge takes a rotated refresh token and its expiry', () {
      final later = DateTime.utc(2026, 3, 1, 13);
      final merged = tokens.merge(
        AuthTokens(
          accessToken: 'n',
          refreshToken: 'rotated',
          refreshExpiresAt: later,
        ),
      );
      expect(merged.refreshToken, 'rotated');
      expect(merged.refreshExpiresAt, later);
    });

    test('toString never shows a token', () {
      final text = '$tokens';
      expect(text, isNot(contains('secret')));
      expect(text, contains('type: DPoP'));
      expect(text, contains('refresh: yes'));
      expect(text, contains('id: yes'));
    });
  });

  group('AuthUser', () {
    test(
      'fromClaims reads the id, e-mail and name, and drops volatile claims',
      () {
        final user = AuthUser.fromClaims(
          {
            'sub': 'u-1',
            'email': 'ada@example.com',
            'preferred_username': 'ada',
            'iat': 1,
            'exp': 2,
            'jti': 'x',
            'sid': 's',
            'nonce': 'n',
            'azp': 'app',
            'locale': 'fr',
          },
          roles: {'admin'},
        );
        expect(user.id, 'u-1');
        expect(user.email, 'ada@example.com');
        expect(user.name, 'ada');
        expect(user.roles, {'admin'});
        expect(user.claims, {
          'sub': 'u-1',
          'email': 'ada@example.com',
          'preferred_username': 'ada',
          'locale': 'fr',
        });
      },
    );

    test(
      'name wins over preferred_username, and a claim with no sub is refused',
      () {
        expect(
          AuthUser.fromClaims({
            'sub': 'u',
            'name': 'Ada L',
            'preferred_username': 'ada',
          }).name,
          'Ada L',
        );
        expect(() => AuthUser.fromClaims({'name': 'x'}), throwsFormatException);
        expect(() => AuthUser.fromClaims({'sub': ''}), throwsFormatException);
      },
    );

    test('equality is deep, and ignores iat and exp churn', () {
      final a = AuthUser.fromClaims({
        'sub': 'u',
        'iat': 1,
        'exp': 2,
        'groups': ['a', 'b'],
      });
      final b = AuthUser.fromClaims({
        'sub': 'u',
        'iat': 99,
        'exp': 100,
        'groups': ['a', 'b'],
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          AuthUser.fromClaims({
            'sub': 'u',
            'groups': ['a'],
          }),
        ),
      );
      expect(
        const AuthUser(id: 'u', roles: {'a', 'b'}),
        const AuthUser(id: 'u', roles: {'b', 'a'}),
      );
      expect(
        const AuthUser(id: 'u', roles: {'a'}),
        isNot(const AuthUser(id: 'u')),
      );
    });

    test('toString names the roles and nothing else', () {
      final text = '$ada';
      expect(text, 'AuthUser(roles: {admin})');
      expect(text, isNot(contains('ada')));
    });

    test('survives a JSON round trip', () {
      final back = AuthUser.fromJson(
        jsonDecode(jsonEncode(ada.toJson())) as Map<String, Object?>,
      );
      expect(back, ada);
      expect(back.hasRole('admin'), isTrue);
      expect(back.hasRole('staff'), isFalse);
    });

    test('a stored user that is malformed is a FormatException', () {
      expect(() => AuthUser.fromJson({'id': 'u'}), throwsFormatException);
      expect(
        () => AuthUser.fromJson({
          'id': 'u',
          'roles': [1],
          'claims': <String, Object?>{},
        }),
        throwsFormatException,
      );
    });
  });

  group('AuthSession', () {
    final session = AuthSession(
      backend: 'oidc',
      tokens: tokens,
      user: ada,
      binding: 'thumb',
    );

    test('survives a JSON round trip', () {
      final text = jsonEncode(session.toJson());
      final back = AuthSession.fromJson(
        jsonDecode(text) as Map<String, Object?>,
      );
      expect(back, session);
      expect(back.binding, 'thumb');
      expect(session.toJson()['v'], 1);
    });

    test(
      'an unknown version, a missing part or a wrong type is a FormatException',
      () {
        final json = session.toJson();
        expect(
          () => AuthSession.fromJson({...json, 'v': 2}),
          throwsFormatException,
        );
        expect(
          () => AuthSession.fromJson({...json, 'v': null}),
          throwsFormatException,
        );
        expect(
          () => AuthSession.fromJson({...json, 'tokens': 'x'}),
          throwsFormatException,
        );
        expect(
          () => AuthSession.fromJson({...json, 'backend': 1}),
          throwsFormatException,
        );
        expect(
          () => AuthSession.fromJson({
            ...json,
            'tokens': {...tokens.toJson(), 'expiresAt': 'yesterday'},
          }),
          throwsFormatException,
        );
      },
    );

    test('copyWith swaps the tokens and keeps the binding', () {
      final next = session.copyWith(tokens: const AuthTokens(accessToken: 'n'));
      expect(next.tokens.accessToken, 'n');
      expect(next.user, ada);
      expect(next.binding, 'thumb');
      expect(next, isNot(session));
    });

    test('toString shows no token, id or e-mail', () {
      final text = '$session';
      for (final secret in ['secret', 'ada-id', 'ada@example.com']) {
        expect(text, isNot(contains(secret)));
      }
    });
  });

  group('SessionState', () {
    test('says who is signed in', () {
      final session = AuthSession(backend: 'b', tokens: tokens, user: ada);
      expect(SignedIn(session).isSignedIn, isTrue);
      expect(SignedIn(session).user, ada);
      expect(const SignedOut().isSignedIn, isFalse);
      expect(const SignedOut().user, isNull);
      expect(const SessionRestoring().user, isNull);
    });

    test('SignedOut equals by reason, SignedIn by session', () {
      expect(const SignedOut(), const SignedOut());
      expect(
        const SignedOut(reason: SignOutReason.expired),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(
        const SignedOut(),
        isNot(const SignedOut(reason: SignOutReason.user)),
      );
      final one = AuthSession(backend: 'b', tokens: tokens, user: ada);
      final two = AuthSession(backend: 'b', tokens: tokens, user: ada);
      expect(SignedIn(one), SignedIn(two));
      expect(SignedIn(one).hashCode, SignedIn(two).hashCode);
    });
  });

  group('PasswordSignIn', () {
    test('toString hides the user name and the password', () {
      const request = PasswordSignIn(username: 'ada', password: 'hunter2');
      expect('$request', isNot(contains('ada')));
      expect('$request', isNot(contains('hunter2')));
    });
  });

  group('unverifiedJwtClaims', () {
    String part(Object json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

    test('reads the payload of a JWT built at run time', () {
      final token =
          '${part({'alg': 'none'})}.${part({
            'sub': 'u',
            'roles': ['a'],
          })}.sig';
      expect(unverifiedJwtClaims(token), {
        'sub': 'u',
        'roles': ['a'],
      });
    });

    test('is null for anything that is not a JWT', () {
      expect(unverifiedJwtClaims('abc'), isNull);
      expect(unverifiedJwtClaims('a.b.c'), isNull);
      expect(unverifiedJwtClaims('a.${part([1])}.c'), isNull);
      expect(unverifiedJwtClaims('a.${part('text')}.c'), isNull);
    });
  });
}
