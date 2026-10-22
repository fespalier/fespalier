// Enrolment is sign-in: two unsigned legs, a challenge signed by each key, an attestation back;
// then the credential, the store and the backend's own checks.
import 'dart:convert';

import 'package:fespalier/fespalier.dart' show FieldErrors;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A signer whose key will not delete.
final class StubbornSigner implements KeypairSigner {
  StubbornSigner(this.inner);
  final FakeKeypairSigner inner;
  @override
  KeyRole get role => inner.role;
  @override
  Future<Map<String, String>> publicJwk() => inner.publicJwk();
  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) =>
      inner.sign(signingInput, reason: reason);
  @override
  Future<bool> isHardwareBacked() => inner.isHardwareBacked();
  @override
  Future<bool> exists() => inner.exists();
  @override
  Future<void> deleteKey() async => throw StateError('keystore busy');
}

void main() {
  group('signing in by enrolment', () {
    test(
      'signs in as the user the server resolved, with an attestation per key',
      () async {
        final rig = Rig.create();
        expect(rig.state, const SignedOut());
        final session = await rig.enrol();
        expect(rig.state, isA<SignedIn>());
        expect(session.backend, 'device');
        expect(session.user, rig.server.user);
        expect(rig.credential.deviceId, rig.server.devices.single);
        expect(
          rig.credential.attestations.keys,
          unorderedEquals(KeyRole.values),
        );
        expect(
          rig.credential.attestation(KeyRole.ambient)!.jkt,
          jwkThumbprint(await rig.ambient.publicJwk()),
        );
        expect(
          rig.credential.attestation(KeyRole.userPresent)!.jkt,
          jwkThumbprint(await rig.userPresent!.publicJwk()),
        );
        expect(rig.container.read(isSignedIn), isTrue);
      },
    );

    test(
      'leg one sends both public keys and the app fields; the server never gets a private key',
      () async {
        final rig = Rig.create();
        final challenge = await rig.backend.beginEnrolment(
          fields: const {'phone': '+237600000000'},
        );
        expect(rig.server.startedWith, [
          {'phone': '+237600000000'},
        ]);
        expect(challenge.challenges.keys, unorderedEquals(KeyRole.values));
        expect(rig.ambient.signatures, 0, reason: 'nothing signed in leg one');
        expect(rig.userPresent!.prompts, 0);
      },
    );

    test(
      'leg two signs one challenge per key; only the user-present key prompts',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        expect(rig.ambient.signatures, 1);
        expect(rig.userPresent!.prompts, 1);
        expect(rig.userPresent!.lastReason, isNotNull);
        expect(rig.server.enrolments, 1);
      },
    );

    test(
      'the web: ambient only, and the session works without a user-present key',
      () async {
        final rig = Rig.create(withUserPresent: false);
        await rig.enrol();
        expect(rig.credential.attestations.keys, [KeyRole.ambient]);
        expect((await rig.send('/orders')).statusCode, 200);
        rig.expectAllVerified();
      },
    );

    test(
      'a wrong code is a FieldErrors, the state stays SignedOut, and the same keys enrol on the next try',
      () async {
        final rig = Rig.create();
        final jwk = await rig.ambient.publicJwk();
        await expectLater(
          rig.enrol(code: '000000'),
          throwsA(
            isA<FieldErrors>().having((e) => e.fields.keys, 'fields', ['otp']),
          ),
        );
        expect(rig.state, const SignedOut());
        expect(rig.store.value, isNull);
        await rig.enrol();
        expect(rig.state, isA<SignedIn>());
        expect(await rig.ambient.publicJwk(), jwk);
      },
    );

    test('leg one failing is thrown as it is', () async {
      final rig = Rig.create();
      rig.server.beginEnrolmentError = const FieldErrors({'phone': 'unknown'});
      await expectLater(
        rig.backend.beginEnrolment(),
        throwsA(isA<FieldErrors>()),
      );
    });

    test(
      'a refused user-present prompt fails the sign-in and enrols nothing',
      () async {
        final rig = Rig.create();
        rig.userPresent!.refuseNextPrompt();
        await expectLater(rig.enrol(), throwsA(isA<UserPresenceRefused>()));
        expect(rig.state, const SignedOut());
        expect(rig.server.enrolments, 0);
      },
    );

    test(
      'an attestation bound to another key is refused loudly, not kept',
      () async {
        final rig = Rig.create();
        final other = await FakeKeypairSigner(seed: 'another key').publicJwk();
        final server = _WrongKeyServer(rig.server, other);
        final backend = DeviceAuthBackend(
          server: server,
          keys: rig.backend.keys,
          profile: profile,
        );
        final challenge = await backend.beginEnrolment();
        await expectLater(
          backend.signIn(CompleteEnrolment(challenge, proof: rig.server.otp)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('bound to another key'),
            ),
          ),
        );
      },
    );

    test('only CompleteEnrolment signs a DeviceAuthBackend in', () async {
      final rig = Rig.create();
      expect(() => rig.backend.signIn(const _Other()), throwsArgumentError);
    });

    test(
      'the session is stored as v2 with the attestations only, and no token',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        final stored = jsonDecode(rig.store.value!) as Map<String, Object?>;
        expect(stored['v'], 2);
        expect(stored['backend'], 'device');
        final credential = stored['credential']! as Map<String, Object?>;
        expect(credential.keys, unorderedEquals(['deviceId', 'attestations']));
        expect(rig.store.value, isNot(contains('access_token')));
        expect(
          rig.store.value,
          isNot(contains('"d"')),
          reason: 'no private key',
        );
      },
    );
  });

  group('DeviceCredential and Attestation', () {
    test(
      'a credential round-trips through JSON and compares by value',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        final read = DeviceCredential.fromJson(
          jsonDecode(jsonEncode(rig.credential.toJson()))
              as Map<String, Object?>,
        );
        expect(read, rig.credential);
        expect(read.hashCode, rig.credential.hashCode);
        expect(
          read.expiresAt,
          rig.credential.attestation(KeyRole.ambient)!.expiresAt,
        );
        expect(read.renewable, isTrue);
        expect(read.renewableUntil, isNull);
      },
    );

    test('toString shows no id, no JWS and no thumbprint', () async {
      final rig = Rig.create();
      await rig.enrol();
      final text =
          '${rig.credential} ${rig.credential.attestation(KeyRole.ambient)}';
      expect(text, isNot(contains(rig.credential.deviceId)));
      expect(
        text,
        isNot(contains(rig.credential.attestation(KeyRole.ambient)!.jws)),
      );
      expect(
        text,
        isNot(contains(rig.credential.attestation(KeyRole.ambient)!.jkt)),
      );
    });

    test('a credential needs an ambient attestation', () async {
      final rig = Rig.create();
      await rig.enrol();
      expect(
        () => DeviceCredential(
          deviceId: 'd',
          attestations: {
            KeyRole.userPresent: rig.credential.attestation(
              KeyRole.userPresent,
            )!,
          },
        ),
        throwsArgumentError,
      );
    });

    test('malformed stored credentials are FormatExceptions', () {
      for (final json in <Map<String, Object?>>[
        {},
        {'deviceId': 'd'},
        {'deviceId': 'd', 'attestations': <String, Object?>{}},
        {
          'deviceId': 'd',
          'attestations': {'ambient': 3},
        },
        {
          'deviceId': 'd',
          'attestations': {'nonsense': 'a.b.c'},
        },
        {
          'deviceId': 'd',
          'attestations': {'ambient': 'a.b.c'},
        },
      ]) {
        expect(
          () => DeviceCredential.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });

    test(
      'Attestation.parse reads exp and cnf.jkt without verifying, and refuses the rest',
      () {
        String jws(Object? claims) =>
            'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.c2ln';
        final ok = Attestation.parse(
          jws({
            'exp': 1000,
            'cnf': {'jkt': 'abc'},
          }),
        );
        expect(
          ok.expiresAt,
          DateTime.fromMillisecondsSinceEpoch(1000000, isUtc: true),
        );
        expect(ok.jkt, 'abc');
        for (final bad in [
          '',
          'a.b',
          'a..c',
          jws({'exp': 1}),
          jws({
            'cnf': {'jkt': 'x'},
          }),
          jws({
            'exp': 'x',
            'cnf': {'jkt': 'x'},
          }),
          jws([1]),
          'a.!!.c',
        ]) {
          expect(
            () => Attestation.parse(bad),
            throwsFormatException,
            reason: bad,
          );
        }
      },
    );
  });

  group('the backend', () {
    test('check: the ambient key decides', () async {
      final rig = Rig.create();
      final session = await rig.enrol();
      expect(await rig.backend.check(session), isNull);
      await rig.userPresent!.loseKey();
      expect(await rig.backend.check(session), isNull);
      await rig.ambient.loseKey();
      expect(await rig.backend.check(session), SignOutReason.keyLost);
      await rig.ambient.publicJwk();
      expect(
        await rig.backend.check(session),
        SignOutReason.keyLost,
        reason: 'a new key is not the enrolled one',
      );
    });

    test('check never makes a key', () async {
      final rig = Rig.create();
      final session = await rig.enrol();
      await rig.ambient.loseKey();
      await rig.backend.check(session);
      expect(await rig.ambient.exists(), isFalse);
    });

    test(
      'renew keeps the other role untouched and checks the new attestation is bound',
      () async {
        final rig = Rig.create();
        final session = await rig.enrol();
        final renewed = await rig.backend.renew(session);
        final before = session.credential as DeviceCredential;
        final after = renewed.credential as DeviceCredential;
        expect(after.deviceId, before.deviceId);
        expect(
          after.attestation(KeyRole.userPresent),
          before.attestation(KeyRole.userPresent),
        );
        expect(renewed.user, session.user);
      },
    );

    test(
      'renew: a revoked device is AuthEnded(revoked); anything else is thrown as it is',
      () async {
        final rig = Rig.create();
        final session = await rig.enrol();
        rig.server.revokeDevice(rig.credential.deviceId);
        await expectLater(
          rig.backend.renew(session),
          throwsA(
            isA<AuthEnded>().having(
              (e) => e.reason,
              'reason',
              SignOutReason.revoked,
            ),
          ),
        );
        rig.server.renewalError = StateError('boom');
        await expectLater(rig.backend.renew(session), throwsStateError);
      },
    );

    test(
      'discard tries both keys even when one will not delete, then throws',
      () async {
        final rig = Rig.create();
        final session = await rig.enrol();
        final backend = DeviceAuthBackend(
          server: rig.server,
          keys: DeviceKeys(
            ambient: StubbornSigner(rig.ambient),
            userPresent: rig.userPresent,
          ),
          profile: profile,
        );
        await expectLater(backend.discard(session), throwsStateError);
        expect(rig.userPresent!.deletes, 1);
      },
    );

    test('DeviceKeys refuses a signer of the wrong role', () {
      expect(
        () => DeviceKeys(ambient: FakeKeypairSigner(role: KeyRole.userPresent)),
        throwsArgumentError,
      );
      expect(
        () => DeviceKeys(
          ambient: FakeKeypairSigner(),
          userPresent: FakeKeypairSigner(),
        ),
        throwsArgumentError,
      );
    });

    test(
      'DeviceKeys.device: both keys on a phone, ambient only where there is no secure element',
      () {
        expect(DeviceKeys.device().roles, KeyRole.values);
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        try {
          expect(() => DeviceKeys.device(), throwsA(isA<KeypairUnavailable>()));
          final keys = DeviceKeys.device(fallback: KeypairFallback.software);
          expect(keys.roles, [KeyRole.ambient]);
          expect(keys.userPresent, isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    test('the backend names itself device', () {
      final rig = Rig.create();
      expect(rig.backend.name, 'device');
      expect(rig.backend.scheme, 'device');
      expect(rig.backend.renewAhead, const Duration(hours: 12));
      expect(rig.backend.keepsOwnSession, isFalse);
    });
  });
}

final class _Other extends SignInRequest {
  const _Other();
}

/// A server that binds the ambient attestation to a key of its own choosing.
final class _WrongKeyServer implements DeviceAuthServer {
  _WrongKeyServer(this.inner, this.wrong);
  final FakeDeviceAuthServer inner;
  final Map<String, String> wrong;

  @override
  Future<EnrolmentChallenge> beginEnrolment(EnrolmentStart start) =>
      inner.beginEnrolment(start);

  @override
  Future<DeviceEnrolment> confirmEnrolment(
    EnrolmentChallenge challenge,
    Map<KeyRole, String> challengeSignatures,
    Object? proof,
  ) async {
    final real = await inner.confirmEnrolment(
      challenge,
      challengeSignatures,
      proof,
    );
    return DeviceEnrolment(
      deviceId: real.deviceId,
      attestations: {
        ...real.attestations,
        KeyRole.ambient: await inner.issue(deviceId: real.deviceId, jwk: wrong),
      },
      user: real.user,
    );
  }

  @override
  Future<RoleChallenge> beginRenewal(String deviceId, KeyRole role) =>
      inner.beginRenewal(deviceId, role);

  @override
  Future<Attestation> confirmRenewal(
    RoleChallenge challenge,
    String signature,
  ) => inner.confirmRenewal(challenge, signature);

  @override
  Future<void> revoke(DeviceCredential credential, DeviceSigner signer) =>
      inner.revoke(credential, signer);
}
