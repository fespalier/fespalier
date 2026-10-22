// The user a token makes: `userFromClaims`, the sign-in requests and the unverified claims.
import 'dart:convert';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('userFromClaims', () {
    test('reads the id, e-mail and name, and drops volatile claims', () {
      final user = userFromClaims(
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
    });

    test('drops every volatile claim', () {
      final user = userFromClaims({
        'sub': 'u',
        for (final claim in volatileClaims) claim: 'x',
        'keep': 1,
      });
      expect(user.claims, {'sub': 'u', 'keep': 1});
      expect(
        volatileClaims,
        containsAll(<String>['iat', 'exp', 'nbf', 'jti', 'nonce', 'sid']),
      );
    });

    test(
      'name wins over preferred_username, and a claim with no sub is refused',
      () {
        expect(
          userFromClaims({
            'sub': 'u',
            'name': 'Ada L',
            'preferred_username': 'ada',
          }).name,
          'Ada L',
        );
        expect(() => userFromClaims({'name': 'x'}), throwsFormatException);
        expect(() => userFromClaims({'sub': ''}), throwsFormatException);
        expect(() => userFromClaims({'sub': 5}), throwsFormatException);
      },
    );

    test('an e-mail or a name that is not a string is ignored', () {
      final user = userFromClaims({'sub': 'u', 'email': 5, 'name': <int>[]});
      expect(user.email, isNull);
      expect(user.name, isNull);
    });

    test(
      'the result is an AuthUser whose equality ignores iat and exp churn',
      () {
        final a = userFromClaims({
          'sub': 'u',
          'iat': 1,
          'exp': 2,
          'groups': ['a', 'b'],
        });
        final b = userFromClaims({
          'sub': 'u',
          'iat': 99,
          'exp': 100,
          'groups': ['a', 'b'],
        });
        expect(a, isA<AuthUser>());
        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(
          a,
          isNot(
            userFromClaims({
              'sub': 'u',
              'groups': ['a'],
            }),
          ),
        );
      },
    );
  });

  group('PasswordSignIn', () {
    test('toString hides the user name and the password', () {
      const request = PasswordSignIn(username: 'ada', password: 'hunter2');
      expect('$request', isNot(contains('ada')));
      expect('$request', isNot(contains('hunter2')));
    });

    test('is a SignInRequest, like BrowserSignIn', () {
      expect(
        const PasswordSignIn(username: 'a', password: 'b'),
        isA<SignInRequest>(),
      );
      const browser = BrowserSignIn(loginHint: 'ada', prompt: 'login');
      expect(browser, isA<SignInRequest>());
      expect(browser.loginHint, 'ada');
      expect(browser.prompt, 'login');
      expect(const BrowserSignIn().parameters, isEmpty);
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

    test('reads a payload whose base64url has padding', () {
      final payload = base64Url.encode(utf8.encode(jsonEncode({'sub': 'ab'})));
      expect(unverifiedJwtClaims('h.$payload.s'), {'sub': 'ab'});
    });

    test('is null for anything that is not a JWT', () {
      expect(unverifiedJwtClaims('abc'), isNull);
      expect(unverifiedJwtClaims('a.b.c'), isNull);
      expect(unverifiedJwtClaims('a.${part([1])}.c'), isNull);
      expect(unverifiedJwtClaims('a.${part('text')}.c'), isNull);
      expect(unverifiedJwtClaims('a.b'), isNull);
      expect(unverifiedJwtClaims('a.b.c.d'), isNull);
    });
  });
}
