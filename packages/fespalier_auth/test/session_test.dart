// The values a session is made of: JSON round trips, equality, and what `toString` never shows.
import 'dart:convert';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final expires = DateTime.utc(2026, 3, 1, 12, 5);
  final credential = FakeCredential(
    id: 'fake-7',
    expiresAt: expires,
    renewableUntil: DateTime.utc(2026, 3, 1, 12, 30),
  );

  group('AuthUser', () {
    test('equality is deep over roles and claims', () {
      const a = AuthUser(
        id: 'u',
        roles: {'a', 'b'},
        claims: {
          'groups': ['a', 'b'],
        },
      );
      const b = AuthUser(
        id: 'u',
        roles: {'b', 'a'},
        claims: {
          'groups': ['a', 'b'],
        },
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          const AuthUser(
            id: 'u',
            roles: {'a', 'b'},
            claims: {
              'groups': ['a'],
            },
          ),
        ),
      );
      expect(
        const AuthUser(id: 'u', roles: {'a'}),
        isNot(const AuthUser(id: 'u')),
      );
      expect(const AuthUser(id: 'u'), isNot(const AuthUser(id: 'v')));
      expect(
        const AuthUser(id: 'u', email: 'a@b.c'),
        isNot(const AuthUser(id: 'u')),
      );
      expect(
        const AuthUser(id: 'u', name: 'A'),
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

    test('roles are written sorted, so the stored text is stable', () {
      const user = AuthUser(id: 'u', roles: {'z', 'a', 'm'});
      expect(user.toJson()['roles'], ['a', 'm', 'z']);
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
      expect(
        () => AuthUser.fromJson({
          'id': 1,
          'roles': <Object?>[],
          'claims': <String, Object?>{},
        }),
        throwsFormatException,
      );
      expect(
        () => AuthUser.fromJson({
          'id': 'u',
          'roles': <Object?>[],
          'claims': <String, Object?>{},
          'email': 3,
        }),
        throwsFormatException,
      );
    });
  });

  group('AuthSession', () {
    final session = AuthSession(
      backend: 'fake',
      credential: credential,
      user: ada,
    );

    test('survives a JSON round trip, the credential read by the backend', () {
      final text = jsonEncode(session.toJson());
      final back = AuthSession.fromJson(
        jsonDecode(text) as Map<String, Object?>,
        FakeCredential.fromJson,
      );
      expect(back, session);
      expect(back.hashCode, session.hashCode);
      expect(back.credential, credential);
      expect(back.backend, 'fake');
      expect(session.toJson()['v'], 2);
    });

    test('the credential is read through the function it is given', () {
      final read = <Map<String, Object?>>[];
      AuthSession.fromJson(session.toJson(), (json) {
        read.add(json);
        return FakeCredential.fromJson(json);
      });
      expect(read, [credential.toJson()]);
    });

    test('a credential the reader refuses is a FormatException', () {
      final json = session.toJson();
      expect(
        () => AuthSession.fromJson({
          ...json,
          'credential': <String, Object?>{'id': 1},
        }, FakeCredential.fromJson),
        throwsFormatException,
      );
    });

    test(
      'version 1 (0.20.0 and before) and any unknown version is refused',
      () {
        final json = session.toJson();
        for (final v in <Object?>[1, 3, null, '2']) {
          expect(
            () => AuthSession.fromJson({
              ...json,
              'v': v,
            }, FakeCredential.fromJson),
            throwsFormatException,
            reason: 'v: $v',
          );
        }
        expect(
          () => AuthSession.fromJson(<String, Object?>{
            'v': 1,
            'backend': 'oidc',
            'tokens': <String, Object?>{'accessToken': 'a'},
            'user': ada.toJson(),
          }, FakeCredential.fromJson),
          throwsFormatException,
        );
      },
    );

    test('a missing part or a wrong type is a FormatException', () {
      final json = session.toJson();
      expect(
        () => AuthSession.fromJson({
          ...json,
          'credential': 'x',
        }, FakeCredential.fromJson),
        throwsFormatException,
      );
      expect(
        () => AuthSession.fromJson({
          ...json,
          'credential': null,
        }, FakeCredential.fromJson),
        throwsFormatException,
      );
      expect(
        () => AuthSession.fromJson({
          ...json,
          'user': null,
        }, FakeCredential.fromJson),
        throwsFormatException,
      );
      expect(
        () => AuthSession.fromJson({
          ...json,
          'backend': 1,
        }, FakeCredential.fromJson),
        throwsFormatException,
      );
      expect(
        () => AuthSession.fromJson({
          ...json,
          'backend': null,
        }, FakeCredential.fromJson),
        throwsFormatException,
      );
      expect(
        () => AuthSession.fromJson({
          ...json,
          'credential': {...credential.toJson(), 'expiresAt': 'yesterday'},
        }, FakeCredential.fromJson),
        throwsFormatException,
      );
    });

    test('copyWith swaps the credential or the user and keeps the rest', () {
      const next = FakeCredential(id: 'fake-9');
      final renewed = session.copyWith(credential: next);
      expect(renewed.credential, next);
      expect(renewed.user, ada);
      expect(renewed.backend, 'fake');
      expect(renewed, isNot(session));

      final other = session.copyWith(user: bob);
      expect(other.user, bob);
      expect(other.credential, credential);
      expect(other.backend, 'fake');

      expect(session.copyWith(), session);
    });

    test('equality covers the backend, the credential and the user', () {
      final same = AuthSession(
        backend: 'fake',
        credential: credential,
        user: ada,
      );
      expect(session, same);
      expect(
        session,
        isNot(AuthSession(backend: 'other', credential: credential, user: ada)),
      );
      expect(
        session,
        isNot(AuthSession(backend: 'fake', credential: credential, user: bob)),
      );
    });

    test(
      'toString shows no user id or e-mail, and leaves the credential its own',
      () {
        final text = '$session';
        for (final secret in ['ada-id', 'ada@example.com', 'Ada']) {
          expect(text, isNot(contains(secret)));
        }
        expect(text, contains('backend: fake'));
        expect(text, contains('$credential'));
      },
    );

    test('the stored text holds the version, the backend and both parts', () {
      final json = jsonDecode(jsonEncode(session.toJson()));
      expect(json, isA<Map<String, Object?>>());
      expect((json as Map<String, Object?>).keys.toSet(), {
        'v',
        'backend',
        'credential',
        'user',
      });
    });
  });

  group('SessionState', () {
    final session = AuthSession(
      backend: 'fake',
      credential: credential,
      user: ada,
    );

    test('says who is signed in', () {
      expect(SignedIn(session).isSignedIn, isTrue);
      expect(SignedIn(session).user, ada);
      expect(const SignedOut().isSignedIn, isFalse);
      expect(const SignedOut().user, isNull);
      expect(const SessionRestoring().user, isNull);
      expect(const SessionRestoring().isSignedIn, isFalse);
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
      final one = AuthSession(backend: 'b', credential: credential, user: ada);
      final two = AuthSession(backend: 'b', credential: credential, user: ada);
      expect(SignedIn(one), SignedIn(two));
      expect(SignedIn(one).hashCode, SignedIn(two).hashCode);
      expect(SignedIn(one), isNot(SignedIn(one.copyWith(user: bob))));
    });

    test('toString names the state', () {
      expect('${const SessionRestoring()}', 'SessionRestoring()');
      expect('${const SignedOut()}', 'SignedOut()');
      expect(
        '${const SignedOut(reason: SignOutReason.revoked)}',
        'SignedOut(revoked)',
      );
      expect('${SignedIn(session)}', isNot(contains('ada-id')));
    });
  });

  group('SignOutReason', () {
    test('has user, expired, keyLost and revoked', () {
      expect(SignOutReason.values.map((r) => r.name), [
        'user',
        'expired',
        'keyLost',
        'revoked',
      ]);
    });

    test('revoked is its own state, not equal to expired', () {
      expect(
        const SignedOut(reason: SignOutReason.revoked),
        const SignedOut(reason: SignOutReason.revoked),
      );
      expect(
        const SignedOut(reason: SignOutReason.revoked),
        isNot(const SignedOut(reason: SignOutReason.expired)),
      );
    });
  });

  group('FakeCredential', () {
    test('survives a JSON round trip, dates in UTC', () {
      final back = FakeCredential.fromJson(
        jsonDecode(jsonEncode(credential.toJson())) as Map<String, Object?>,
      );
      expect(back, credential);
      expect(back.hashCode, credential.hashCode);
      expect(back.expiresAt!.isUtc, isTrue);
      expect(back.renewable, isTrue);
    });

    test('toString shows the id and nothing else', () {
      expect('$credential', 'FakeCredential(fake-7)');
    });
  });
}
