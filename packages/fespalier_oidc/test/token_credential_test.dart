// The values a token session is made of: JSON round trips, equality, expiry, merge, and what
// `toString` never shows.
import 'dart:convert';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final expires = DateTime.utc(2026, 3, 1, 12, 5);
  final tokens = TokenCredential(
    accessToken: 'access-secret',
    tokenType: 'DPoP',
    refreshToken: 'refresh-secret',
    idToken: 'id-secret',
    expiresAt: expires,
    refreshExpiresAt: DateTime.utc(2026, 3, 1, 12, 30),
    scope: 'openid email',
    jkt: 'thumb',
  );

  group('TokenCredential', () {
    test('is a SessionCredential with the dates and the capability', () {
      final SessionCredential credential = tokens;
      expect(credential.expiresAt, expires);
      expect(credential.renewableUntil, DateTime.utc(2026, 3, 1, 12, 30));
      expect(credential.renewable, isTrue);
    });

    test(
      'renewable is "has a refresh token"; renewableUntil is refreshExpiresAt',
      () {
        const bare = TokenCredential(accessToken: 'a');
        expect(bare.renewable, isFalse);
        expect(bare.renewableUntil, isNull);
        expect(bare.expiresAt, isNull);
        expect(
          const TokenCredential(accessToken: 'a', refreshToken: 'r').renewable,
          isTrue,
        );
        expect(tokens.renewableUntil, tokens.refreshExpiresAt);
      },
    );

    test('survive a JSON round trip, dates in UTC, the key thumbprint too', () {
      final back = TokenCredential.fromJson(
        jsonDecode(jsonEncode(tokens.toJson())) as Map<String, Object?>,
      );
      expect(back, tokens);
      expect(back.hashCode, tokens.hashCode);
      expect(back.expiresAt!.isUtc, isTrue);
      expect(back.refreshExpiresAt!.isUtc, isTrue);
      expect(back.jkt, 'thumb');
    });

    test('a token with nothing but an access token survives it too', () {
      const bare = TokenCredential(accessToken: 'a');
      final back = TokenCredential.fromJson(
        jsonDecode(jsonEncode(bare.toJson())) as Map<String, Object?>,
      );
      expect(back, bare);
      expect(back.tokenType, 'Bearer');
      expect(back.jkt, isNull);
    });

    test('toJson names every field', () {
      expect(tokens.toJson().keys, {
        'accessToken',
        'tokenType',
        'refreshToken',
        'idToken',
        'expiresAt',
        'refreshExpiresAt',
        'scope',
        'jkt',
      });
      expect(tokens.toJson()['expiresAt'], '2026-03-01T12:05:00.000Z');
    });

    test(
      'a missing access token, a wrong type or a bad date is a FormatException',
      () {
        final json = tokens.toJson();
        expect(
          () => TokenCredential.fromJson({...json}..remove('accessToken')),
          throwsFormatException,
        );
        expect(
          () => TokenCredential.fromJson({...json, 'accessToken': 1}),
          throwsFormatException,
        );
        expect(
          () => TokenCredential.fromJson({...json, 'expiresAt': 'yesterday'}),
          throwsFormatException,
        );
        expect(
          () => TokenCredential.fromJson({...json, 'refreshExpiresAt': 5}),
          throwsFormatException,
        );
        expect(
          () => TokenCredential.fromJson({...json, 'jkt': 5}),
          throwsFormatException,
        );
      },
    );

    test('a token type is Bearer unless the response said otherwise', () {
      expect(const TokenCredential(accessToken: 'a').tokenType, 'Bearer');
      expect(const TokenCredential(accessToken: 'a').isDpop, isFalse);
      expect(tokens.isDpop, isTrue);
      expect(
        const TokenCredential(accessToken: 'a', tokenType: 'dpop').isDpop,
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
      expect(
        const TokenCredential(accessToken: 'a').isExpiredAt(expires),
        isFalse,
      );
    });

    test('merge keeps the refresh and ID tokens a response left out', () {
      final refreshed = TokenCredential(
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
        TokenCredential(
          accessToken: 'n',
          refreshToken: 'rotated',
          refreshExpiresAt: later,
        ),
      );
      expect(merged.refreshToken, 'rotated');
      expect(merged.refreshExpiresAt, later);
    });

    test('merge takes the renewed token\'s key, not the old one', () {
      final merged = tokens.merge(const TokenCredential(accessToken: 'n'));
      expect(
        merged.jkt,
        isNull,
        reason: 'the new access token says what it is',
      );
      final rebound = tokens.merge(
        const TokenCredential(accessToken: 'n', jkt: 'other'),
      );
      expect(rebound.jkt, 'other');
    });

    test('bound() keeps everything and sets the key', () {
      final bound = const TokenCredential(
        accessToken: 'a',
        refreshToken: 'r',
      ).bound('k');
      expect(bound.jkt, 'k');
      expect(bound.accessToken, 'a');
      expect(bound.refreshToken, 'r');
      expect(bound.bound(null).jkt, isNull);
    });

    test('equality is by value, over every field', () {
      expect(
        const TokenCredential(accessToken: 'a'),
        const TokenCredential(accessToken: 'a'),
      );
      expect(
        const TokenCredential(accessToken: 'a'),
        isNot(const TokenCredential(accessToken: 'b')),
      );
      expect(
        const TokenCredential(accessToken: 'a', jkt: 'k'),
        isNot(const TokenCredential(accessToken: 'a')),
      );
    });

    test('toString never shows a token or a key', () {
      final text = '$tokens';
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('thumb')));
      expect(text, contains('type: DPoP'));
      expect(text, contains('refresh: yes'));
      expect(text, contains('id: yes'));
    });
  });

  group('AuthSession over a TokenCredential', () {
    final session = AuthSession(backend: 'oidc', credential: tokens, user: ada);

    test('survives a JSON round trip through the credential reader', () {
      final text = jsonEncode(session.toJson());
      final back = AuthSession.fromJson(
        jsonDecode(text) as Map<String, Object?>,
        TokenCredential.fromJson,
      );
      expect(back, session);
      expect(back.credential, tokens);
      expect(session.toJson()['v'], 2);
    });

    test('has no binding of its own: the key is the credential\'s', () {
      expect(session.toJson().keys, {'v', 'backend', 'credential', 'user'});
      expect((session.credential as TokenCredential).jkt, 'thumb');
    });

    test('a stored credential that is malformed is a FormatException', () {
      final json = session.toJson();
      expect(
        () => AuthSession.fromJson({
          ...json,
          'credential': {...tokens.toJson(), 'expiresAt': 'yesterday'},
        }, TokenCredential.fromJson),
        throwsFormatException,
      );
    });

    test('toString shows no token, id or e-mail', () {
      final text = '$session';
      for (final secret in ['secret', 'ada-id', 'ada@example.com']) {
        expect(text, isNot(contains(secret)));
      }
    });
  });
}
