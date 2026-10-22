// The session around the signature: renewal (proactive, reactive, single-flight), the three
// outcomes of a refused 401, restore, the user-present key and sign-out. Acceptance criteria
// (d) to (h) of fespalier#267.
import 'dart:async';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

TransportResponse expired() => refusal(401, 'attestation_expired');

void main() {
  group('(d) an expired attestation', () {
    test(
      'is renewed once and the request is sent again, signed afresh',
      () => clocked((time) async {
        final rig = Rig.create();
        await rig.enrol();
        time.elapse(const Duration(minutes: 1));
        final first = rig.credential.attestation(KeyRole.ambient)!;
        rig.api.script.add(expired());
        final response = await rig.send('/orders');
        expect(response.statusCode, 200);
        expect(rig.server.renewals, 1);
        expect(rig.server.renewalRequests, [KeyRole.ambient]);
        final sends = rig.api.seen;
        expect(sends, hasLength(2));
        expect(sends[0].attestation, first.jws);
        expect(
          sends[1].attestation,
          rig.credential.attestation(KeyRole.ambient)!.jws,
        );
        expect(sends[1].attestation, isNot(first.jws));
        expect(sends[1].verified, isNotNull, reason: 'the retry verifies');
        expect(sends[0].jti, isNot(sends[1].jti));
        expect(sends[1].request.attributes[transportReplayKey], true);
      }),
    );

    test('is not renewed a second time for the same request', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.api.script.addAll([expired(), expired()]);
      final response = await rig.send('/orders');
      expect(response.statusCode, 401);
      expect(rig.server.renewals, 1);
      expect(rig.api.seen, hasLength(2));
      expect(rig.state, isA<SignedIn>());
    });

    test('concurrent 401s share one renewal', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.server.renewalGate = Completer<void>();
      rig.api.script.addAll([expired(), expired()]);
      final a = rig.send('/a');
      final b = rig.send('/b');
      await pumpEventQueue();
      expect(
        rig.api.seen,
        hasLength(2),
        reason: 'both were refused, none resent yet',
      );
      expect(
        rig.server.renewalRequests,
        hasLength(1),
        reason: 'one renewal started',
      );
      rig.server.renewalGate!.complete();
      expect((await a).statusCode, 200);
      expect((await b).statusCode, 200);
      expect(rig.server.renewals, 1);
      expect(rig.server.renewalRequests, hasLength(1));
      expect(rig.api.seen, hasLength(4));
      rig.expectAllVerified();
      expect(rig.api.verifiedJtis.toSet(), hasLength(4));
    });

    test('device_not_active renews the same way', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.api.script.add(refusal(401, 'device_not_active'));
      expect((await rig.send('/orders')).statusCode, 200);
      expect(rig.server.renewals, 1);
    });

    test(
      'a renewal that could not ask (offline) leaves the session, and the next request asks again',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        rig.api.script.add(expired());
        rig.server.renewalError = const TransportUnsent();
        await expectLater(rig.send('/orders'), throwsA(isA<AuthUnavailable>()));
        expect(rig.state, isA<SignedIn>());
        expect(rig.ambient.deletes, 0);
        rig.server.renewalError = null;
        rig.api.script.add(expired());
        expect((await rig.send('/orders')).statusCode, 200);
        expect(rig.server.renewals, 1);
      },
    );

    test(
      'a 403 from the renewal means the device is dead: SignedOut(revoked), keys deleted',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        rig.api.script.add(expired());
        rig.server.renewalError = const AuthRejected('device_revoked');
        // The refusal stands as the answer; the session is over.
        final response = await rig.send('/orders');
        expect(response.statusCode, 401);
        expect(rig.state, const SignedOut(reason: SignOutReason.revoked));
        await pumpEventQueue();
        expect(rig.ambient.deletes, 1);
        expect(rig.userPresent!.deletes, 1);
        expect(rig.store.value, isNull);
      },
    );
  });

  group('the renewal window', () {
    test(
      'an attestation within 12 hours of expiry is renewed before the send',
      () async {
        final time = TestTime();
        await time.run(() async {
          final rig = Rig.create();
          await rig.enrol();
          final first = rig.credential.attestation(KeyRole.ambient)!;
          time.elapse(const Duration(hours: 11));
          await rig.send('/orders');
          expect(rig.server.renewals, 0, reason: '13 h left: not yet');
          time.elapse(const Duration(hours: 2));
          await rig.send('/orders');
          expect(rig.server.renewals, 1);
          expect(rig.api.seen.last.attestation, isNot(first.jws));
          expect(
            rig.api.seen,
            hasLength(2),
            reason: 'proactive: no 401 in between',
          );
          rig.expectAllVerified();
          // The renewed credential is what the store keeps.
          expect(
            rig.store.value,
            contains(rig.credential.attestation(KeyRole.ambient)!.jws),
          );
        });
      },
    );

    test('many requests inside the window share one renewal', () async {
      final time = TestTime();
      await time.run(() async {
        final rig = Rig.create();
        await rig.enrol();
        time.elapse(const Duration(hours: 13));
        rig.server.renewalGate = Completer<void>();
        final sends = [for (var i = 0; i < 5; i++) rig.send('/o$i')];
        await pumpEventQueue();
        expect(rig.server.renewalRequests, hasLength(1));
        rig.server.renewalGate!.complete();
        await Future.wait(sends);
        expect(rig.server.renewals, 1);
        rig.expectAllVerified();
      });
    });
  });

  group('(e) a refused 401', () {
    for (final code in ['key_not_bound', 'bad_jwk', 'missing_credential']) {
      test(
        '$code is confirmed dead: SignedOut(keyLost) and both keys deleted',
        () async {
          final rig = Rig.create();
          await rig.enrol();
          rig.api.script.add(refusal(401, code));
          await expectLater(rig.send('/orders'), throwsA(isA<AuthRejected>()));
          expect(rig.state, const SignedOut(reason: SignOutReason.keyLost));
          expect(rig.ambient.deletes, 1);
          expect(rig.userPresent!.deletes, 1);
          expect(rig.store.value, isNull);
          expect(rig.api.seen, hasLength(1), reason: 'no retry');
          expect(
            rig.server.revocations,
            isEmpty,
            reason: 'the server said so: no call to it',
          );
        },
      );
    }

    test('an ambiguous 401 wipes nothing and does not loop', () async {
      final rig = Rig.create();
      await rig.enrol();
      for (final body in ['{"error":"rate_limited"}', 'upstream down', '']) {
        rig.api.script.add(fakeResponse(401, body: body));
        final response = await rig.send('/orders');
        expect(response.statusCode, 401);
      }
      expect(rig.state, isA<SignedIn>());
      expect(rig.ambient.deletes, 0);
      expect(rig.userPresent!.deletes, 0);
      expect(rig.server.renewals, 0);
      expect(rig.api.seen, hasLength(3), reason: 'one send each');
      expect(rig.store.value, isNotNull);
    });

    test('403 DEVICE_REVOKED: SignedOut(revoked), keys deleted', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.api.script.add(refusal(403, 'DEVICE_REVOKED'));
      await expectLater(rig.send('/orders'), throwsA(isA<AuthRejected>()));
      expect(rig.state, const SignedOut(reason: SignOutReason.revoked));
      expect(rig.ambient.deletes, 1);
      expect(rig.userPresent!.deletes, 1);
    });

    test('another 403 is the answer, not a sign-out', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.api.script.add(refusal(403, 'forbidden'));
      expect((await rig.send('/orders')).statusCode, 403);
      expect(rig.state, isA<SignedIn>());
    });

    test(
      'a TLS-untrusted failure is a failure of the send, never a session end',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        rig.api.script.add(const TransportUntrusted());
        await expectLater(
          rig.send('/orders'),
          throwsA(isA<TransportUntrusted>()),
        );
        expect(rig.state, isA<SignedIn>());
        expect(rig.ambient.deletes, 0);
      },
    );
  });

  group('(f) restore', () {
    Future<Rig> restored(Rig first) async {
      final next = Rig.create(
        server: first.server,
        ambient: first.ambient,
        userPresent: first.userPresent,
        store: first.store,
      );
      await next.notifier.ready;
      return next;
    }

    test(
      'with the key that was enrolled: signed in, the same credential',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        final next = await restored(rig);
        expect(next.state, isA<SignedIn>());
        expect(next.credential, rig.credential);
        expect(next.ambient.deletes, 0);
        await next.send('/orders');
        next.expectAllVerified();
      },
    );

    test('with a swapped key: SignedOut(keyLost)', () async {
      final rig = Rig.create();
      await rig.enrol();
      await rig.ambient.deleteKey();
      await rig.ambient.publicJwk(); // a new key, not the enrolled one
      final next = await restored(rig);
      expect(next.state, const SignedOut(reason: SignOutReason.keyLost));
      expect(next.store.value, isNull);
    });

    test(
      'with the key gone: SignedOut(keyLost), and the key is not made again',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        await rig.ambient.loseKey();
        final next = await restored(rig);
        expect(next.state, const SignedOut(reason: SignOutReason.keyLost));
        expect(await rig.ambient.exists(), isFalse);
      },
    );

    test('a lost user-present key is not a lost session', () async {
      final rig = Rig.create();
      await rig.enrol();
      await rig.userPresent!.loseKey();
      final next = await restored(rig);
      expect(next.state, isA<SignedIn>());
    });

    test(
      'an expired attestation restores as signed in: the first request renews it',
      () async {
        final time = TestTime();
        await time.run(() async {
          final rig = Rig.create();
          await rig.enrol();
          time.elapse(const Duration(days: 3));
          final next = await restored(rig);
          expect(next.state, isA<SignedIn>());
          await next.send('/orders');
          expect(next.server.renewals, 1);
          next.expectAllVerified();
        });
      },
    );

    test('a corrupt stored credential is dropped', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.store.value = rig.store.value!.replaceAll('"deviceId"', '"id"');
      final next = Rig.create(
        server: rig.server,
        ambient: rig.ambient,
        userPresent: rig.userPresent,
        store: rig.store,
      );
      await next.notifier.ready;
      expect(next.state, const SignedOut());
    });
  });

  group('(g) a user-present request', () {
    test('uses the user-present key and attestation, and prompts', () async {
      final rig = Rig.create();
      await rig.enrol();
      final before = rig.userPresent!.prompts;
      await rig.send(
        '/pay',
        method: 'POST',
        body: [1],
        attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
      );
      expect(rig.userPresent!.prompts, before + 1);
      final sent = rig.api.seen.single;
      expect(
        sent.attestation,
        rig.credential.attestation(KeyRole.userPresent)!.jws,
      );
      expect(
        sent.verified!.thumbprint,
        rig.credential.attestation(KeyRole.userPresent)!.jkt,
      );
      expect(
        sent.verified!.thumbprint,
        isNot(rig.credential.attestation(KeyRole.ambient)!.jkt),
      );
    });

    test('a refused prompt is a clear error and the session goes on', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.userPresent!.refuseNextPrompt();
      await expectLater(
        rig.send(
          '/pay',
          method: 'POST',
          attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
        ),
        throwsA(
          isA<UserPresenceRefused>()
              .having((e) => e.cancelled, 'cancelled', isTrue)
              .having((e) => '$e', 'message', contains('session is unchanged')),
        ),
      );
      expect(rig.api.seen, isEmpty, reason: 'nothing was sent');
      expect(rig.state, isA<SignedIn>());
      expect(rig.userPresent!.deletes, 0);
      // The ambient key still signs, and the user can try again.
      expect((await rig.send('/orders')).statusCode, 200);
      await rig.send(
        '/pay',
        method: 'POST',
        attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
      );
      expect(rig.api.seen, hasLength(2));
    });

    test(
      'a refused attestation renews the user-present one, with a prompt, and the request is resent',
      () => clocked((time) async {
        final rig = Rig.create();
        await rig.enrol();
        time.elapse(const Duration(minutes: 1));
        final before = rig.userPresent!.prompts;
        final old = rig.credential.attestation(KeyRole.userPresent)!;
        rig.api.script.add(expired());
        await rig.send(
          '/pay',
          method: 'POST',
          attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
        );
        expect(rig.server.renewalRequests, [KeyRole.userPresent]);
        // Signature of the first send, the renewal's challenge, signature of the second send.
        expect(rig.userPresent!.prompts, before + 3);
        expect(rig.credential.attestation(KeyRole.userPresent), isNot(old));
        expect(
          rig.api.seen.last.attestation,
          rig.credential.attestation(KeyRole.userPresent)!.jws,
        );
        expect(rig.server.renewals, 1);
      }),
    );

    test(
      'a refused prompt for the renewal challenge is an AuthUnavailable that names it',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        final challenge = await rig.server.beginRenewal(
          rig.credential.deviceId,
          KeyRole.userPresent,
        );
        expect(challenge.role, KeyRole.userPresent);
        rig.userPresent!.refuseNextPrompt();
        await expectLater(
          rig.notifier.credential(forceRenew: true, hint: KeyRole.userPresent),
          throwsA(
            isA<AuthUnavailable>().having(
              (e) => e.cause,
              'cause',
              isA<UserPresenceRefused>(),
            ),
          ),
        );
        expect(rig.state, isA<SignedIn>());
        expect(rig.userPresent!.deletes, 0);
      },
    );
  });

  group('(h) sign-out', () {
    test(
      'revokes the device with the user-present key, then deletes both keys and the store',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        final before = rig.userPresent!.prompts;
        await rig.notifier.signOut();
        expect(rig.state, const SignedOut(reason: SignOutReason.user));
        expect(rig.server.revocations, hasLength(1));
        expect(
          rig.server.revocations.single.deviceId,
          rig.server.devices.single,
        );
        expect(rig.server.revokeSignedWith, [KeyRole.userPresent]);
        expect(rig.userPresent!.prompts, before + 1);
        expect(rig.ambient.deletes, 1);
        expect(rig.userPresent!.deletes, 1);
        expect(rig.store.value, isNull);
      },
    );

    test(
      'revokes with the ambient key on a device that has no user-present key',
      () async {
        final rig = Rig.create(withUserPresent: false);
        await rig.enrol();
        await rig.notifier.signOut();
        expect(rig.server.revokeSignedWith, [KeyRole.ambient]);
        expect(rig.ambient.deletes, 1);
      },
    );

    test('the keys are deleted even when the revoke fails', () async {
      final rig = Rig.create();
      await rig.enrol();
      rig.server.revokeError = const TransportUnsent();
      await rig.notifier.signOut();
      expect(rig.state, const SignedOut(reason: SignOutReason.user));
      expect(rig.ambient.deletes, 1);
      expect(rig.userPresent!.deletes, 1);
      expect(rig.store.value, isNull);
    });

    test(
      'the keys are deleted even when the user refuses the revoke prompt',
      () async {
        final rig = Rig.create();
        await rig.enrol();
        rig.userPresent!.refuseNextPrompt();
        await rig.notifier.signOut();
        expect(rig.server.revocations, hasLength(1));
        expect(
          rig.server.revokeHeaders,
          isEmpty,
          reason: 'it was never signed',
        );
        expect(rig.ambient.deletes, 1);
        expect(rig.userPresent!.deletes, 1);
      },
    );
  });
}
