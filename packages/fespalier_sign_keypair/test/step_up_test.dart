// Step-up for device sessions (since 0.25.0, fespalier#309 and #310): a step-up refusal (RFC 9470,
// what CrateStack's `@authn` answers) makes that one request send once more, signed with the
// user-present key. Never for background work, never twice, never for a send that was already
// user-present; a refused prompt leaves the server's refusal standing and the session as it was.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// CrateStack's challenge: `Bearer`, whatever the provider.
const challenge =
    'Bearer error="insufficient_user_authentication", '
    'error_description="step-up authentication required"';

/// The refusal as CrateStack's REST binding answers it: the JSON envelope and the challenge.
TransportResponse restStepUp() => fakeResponse(
  401,
  headers: const {
    'content-type': 'application/json',
    'www-authenticate': challenge,
  },
  body: jsonEncode({
    'code': 'UNAUTHENTICATED',
    'message': 'step-up authentication required',
    'error': 'insufficient_user_authentication',
    'details': {
      'amr': ['user'],
      'unmet': ['amr'],
    },
  }),
);

/// The refusal as CrateStack's RPC binding answers it over CBOR: the challenge, and a body that is
/// not text (here bytes that are not UTF-8, as a CBOR map's often are not).
TransportResponse rpcStepUp() => TransportResponse(
  statusCode: 401,
  headers: const {
    'content-type': 'application/cbor',
    'www-authenticate': challenge,
  },
  body: Stream<List<int>>.value(Uint8List.fromList([0xa3, 0xff, 0xfe, 0x80])),
);

/// Enrols the device, then forgets the prompt the enrolment showed (it signs the user-present
/// key's challenge), so a test counts its own.
Future<void> enrolled(Rig rig) async {
  await rig.enrol();
  rig.userPresent?.prompts = 0;
}

void main() {
  group('a step-up refusal', () {
    test(
      'on the REST shape: the request is sent once more, signed with the user-present key',
      () async {
        final rig = Rig.create();
        await enrolled(rig);
        rig.api.script.add(restStepUp());
        final response = await rig.send(
          '/orders/1/pay',
          method: 'POST',
          body: utf8.encode('{"id":1}'),
        );
        expect(response.statusCode, 200);
        expect(rig.userPresent!.prompts, 1, reason: 'one prompt, one proof');
        final sends = rig.api.seen;
        expect(sends, hasLength(2));
        expect(
          sends[0].attestation,
          rig.credential.attestation(KeyRole.ambient)!.jws,
        );
        expect(
          sends[1].attestation,
          rig.credential.attestation(KeyRole.userPresent)!.jws,
        );
        expect(
          sends[1].verified!.thumbprint,
          rig.credential.attestation(KeyRole.userPresent)!.jkt,
        );
        expect(sends[1].jti, isNot(sends[0].jti));
        expect(sends[1].body, sends[0].body, reason: 'the same bytes');
        expect(sends[1].request.attributes[transportReplayKey], true);
        rig.expectAllVerified();
        expect(rig.state, isA<SignedIn>());
      },
    );

    test(
      'on the RPC shape: the challenge alone is enough (CBOR is not text)',
      () async {
        final rig = Rig.create();
        await enrolled(rig);
        rig.api.script.add(rpcStepUp());
        final response = await rig.send(
          '/rpc/procedure.payOrder',
          method: 'POST',
          body: [0xa1, 0x64, 0x61, 0x72, 0x67, 0x73, 0xa0],
        );
        expect(response.statusCode, 200);
        expect(rig.userPresent!.prompts, 1);
        expect(
          rig.api.seen.last.attestation,
          rig.credential.attestation(KeyRole.userPresent)!.jws,
        );
      },
    );

    test('is read whatever the challenge\'s scheme', () async {
      for (final scheme in ['DPoP', 'Device', 'bearer']) {
        final rig = Rig.create();
        await enrolled(rig);
        rig.api.script.add(
          fakeResponse(
            401,
            headers: {
              'www-authenticate':
                  '$scheme error="insufficient_user_authentication"',
            },
          ),
        );
        final response = await rig.send('/orders');
        expect(response.statusCode, 200, reason: scheme);
        expect(rig.userPresent!.prompts, 1, reason: scheme);
      }
    });

    test('is read from a JSON body with no challenge', () async {
      final rig = Rig.create();
      await enrolled(rig);
      rig.api.script.add(refusal(401, 'insufficient_user_authentication'));
      final response = await rig.send('/orders');
      expect(response.statusCode, 200);
      expect(rig.userPresent!.prompts, 1);
    });

    test('is not a renewal and ends nothing', () async {
      final rig = Rig.create();
      await enrolled(rig);
      rig.api.script.add(restStepUp());
      final stored = rig.store.value;
      await rig.send('/orders');
      expect(rig.server.renewals, 0);
      expect(
        rig.store.value,
        stored,
        reason: 'the stored session is unchanged',
      );
    });
  });

  group('at most once', () {
    test('a second refusal is the answer, with no second prompt', () async {
      final rig = Rig.create();
      await enrolled(rig);
      rig.api.script.addAll([restStepUp(), restStepUp()]);
      final response = await rig.send('/orders');
      expect(response.statusCode, 401);
      expect(
        await text(response),
        contains('insufficient_user_authentication'),
      );
      expect(rig.api.seen, hasLength(2));
      expect(rig.userPresent!.prompts, 1);
      expect(rig.state, isA<SignedIn>());
    });

    test(
      'a request already signed with the user-present key is not escalated',
      () async {
        final rig = Rig.create();
        await enrolled(rig);
        rig.api.script.add(restStepUp());
        final response = await rig.send(
          '/orders',
          attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
        );
        expect(response.statusCode, 401);
        expect(rig.api.seen, hasLength(1));
        expect(rig.userPresent!.prompts, 1, reason: 'the first send only');
      },
    );

    test(
      'a retrier above the session sends the escalated request with the user-present key, and it is not escalated again',
      () async {
        final rig = Rig.create();
        await enrolled(rig);
        final memo = TransportMemo();
        rig.api.script.addAll([restStepUp(), fakeResponse(503), restStepUp()]);
        final request = rig.request(
          '/orders',
          attributes: {TransportMemo.key: memo},
        );
        expect((await rig.transport.send(request)).statusCode, 503);
        final again = await rig.transport.send(request);
        expect(again.statusCode, 401);
        expect(rig.api.seen, hasLength(3));
        final userPresent = rig.credential.attestation(KeyRole.userPresent)!;
        expect(rig.api.seen[2].attestation, userPresent.jws);
        expect(rig.userPresent!.prompts, 2);
      },
    );

    test('an expired user-present attestation renews that key', () async {
      final rig = Rig.create();
      await enrolled(rig);
      rig.api.script.addAll([
        restStepUp(),
        refusal(401, 'attestation_expired'),
      ]);
      final response = await rig.send('/orders');
      expect(response.statusCode, 200);
      expect(rig.server.renewalRequests, [KeyRole.userPresent]);
    });
  });

  group('never prompts', () {
    test('for a request whose stepUpAttribute is false', () async {
      final rig = Rig.create();
      await enrolled(rig);
      rig.api.script.add(restStepUp());
      final response = await rig.send(
        '/orders',
        attributes: {Authorizer.stepUpAttribute: false},
      );
      expect(response.statusCode, 401);
      expect(rig.api.seen, hasLength(1));
      expect(rig.userPresent!.prompts, 0);
    });

    test('for a request sent inside Authorizer.unattended', () async {
      final rig = Rig.create();
      await enrolled(rig);
      rig.api.script.add(restStepUp());
      final response = await Authorizer.unattended(() => rig.send('/orders'));
      expect(response.statusCode, 401);
      expect(rig.api.seen, hasLength(1));
      expect(rig.userPresent!.prompts, 0);
    });

    test('on a device with no user-present key: the refusal stands', () async {
      final rig = Rig.create(withUserPresent: false);
      await enrolled(rig);
      rig.api.script.add(restStepUp());
      final response = await rig.send('/orders');
      expect(response.statusCode, 401);
      expect(rig.api.seen, hasLength(1));
    });
  });

  group('a refused prompt', () {
    test('lets the server\'s refusal stand and keeps the session', () async {
      final rig = Rig.create();
      await enrolled(rig);
      rig.userPresent!.refuseNextPrompt();
      rig.api.script.add(restStepUp());
      final response = await rig.send('/orders');
      expect(response.statusCode, 401);
      final refused = jsonDecode(await text(response)) as Map<String, Object?>;
      expect(refused['error'], 'insufficient_user_authentication');
      expect(rig.api.seen, hasLength(1), reason: 'nothing was signed');
      expect(rig.userPresent!.prompts, 1);
      expect(rig.state, isA<SignedIn>());
      expect(rig.userPresent!.deletes, 0);
      expect(rig.ambient.deletes, 0);
      // The ambient key, and the next attempt, still work.
      expect((await rig.send('/orders')).statusCode, 200);
    });

    test(
      'on a first send still fails that request with UserPresenceRefused',
      () async {
        final rig = Rig.create();
        await enrolled(rig);
        rig.userPresent!.refuseNextPrompt();
        await expectLater(
          rig.send(
            '/orders',
            attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
          ),
          throwsA(isA<UserPresenceRefused>()),
        );
        expect(rig.api.seen, isEmpty);
      },
    );

    test('is a ProofDeclined', () {
      expect(
        UserPresenceRefused(
          SecureSignerException(
            SignerErrorCode.userAuthenticationCancelled,
            'cancelled',
          ),
        ),
        isA<ProofDeclined>(),
      );
    });
  });

  group('the caption', () {
    test('is the signer\'s stepUpReason, or the request\'s own', () async {
      final rig = Rig.create();
      await enrolled(rig);
      final signer = rig.backend.authenticator;
      expect(signer.stepUpReason, isNull);
      rig.api.script.add(restStepUp());
      await rig.send(
        '/orders',
        attributes: {DeviceSigner.reasonAttribute: 'Pay order 1'},
      );
      expect(rig.userPresent!.lastReason, 'Pay order 1');
    });

    test('DeviceAuthBackend passes stepUpReason to its signer', () {
      final backend = DeviceAuthBackend(
        server: FakeDeviceAuthServer(),
        keys: DeviceKeys(ambient: FakeKeypairSigner(keyId: 'a')),
        profile: profile,
        stepUpReason: 'Confirm it is you',
      );
      expect(backend.signer.stepUpReason, 'Confirm it is you');
      expect(
        backend.signer.withPolicy(DeviceSigner.requestedRole).stepUpReason,
        'Confirm it is you',
      );
    });
  });

  test('DeviceRefusal.isStepUp', () {
    DeviceRefusal of(int status, {String? header, String? body}) =>
        DeviceRefusal(
          role: KeyRole.ambient,
          statusCode: status,
          headers: {'www-authenticate': ?header},
          body: body,
          retried: false,
        );
    expect(of(401, header: challenge).isStepUp, isTrue);
    expect(of(403, header: challenge).isStepUp, isFalse);
    expect(
      of(401, body: '{"error":"insufficient_user_authentication"}').isStepUp,
      isTrue,
    );
    expect(of(401, body: '{"error":"attestation_expired"}').isStepUp, isFalse);
    expect(of(401, header: 'Bearer error="invalid_token"').isStepUp, isFalse);
    expect(of(401).isStepUp, isFalse);
  });
}
