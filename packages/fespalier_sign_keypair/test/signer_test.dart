// The per-send signature, exactly the profile: headers, claims, no Authorization, the bytes that
// are hashed, the key that signs, and what is refused before anything is sent.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> part(String jws, int index) =>
    jsonDecode(utf8.decode(base64UrlDecodeLoose(jws.split('.')[index])))
        as Map<String, Object?>;

String hex(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  test(
    'a send carries X-Attestation and X-Signature and no Authorization',
    () async {
      final rig = Rig.create();
      await rig.enrol();
      await rig.send('/orders');
      final sent = rig.api.seen.single;
      expect(
        sent.lowerHeaders.keys,
        containsAll(['x-attestation', 'x-signature']),
      );
      expect(sent.lowerHeaders.keys, isNot(contains('authorization')));
      expect(
        sent.attestation,
        rig.credential.attestation(KeyRole.ambient)!.jws,
      );
      rig.expectAllVerified();
    },
  );

  test('the signature has the profile header and claims, in order', () async {
    final rig = Rig.create();
    await rig.enrol();
    await rig.send(
      '/orders/42?page=2&sort=asc',
      method: 'POST',
      body: utf8.encode('{"a":1}'),
    );
    final jws = rig.api.seen.single.signature!;
    final header = part(jws, 0);
    expect(header.keys, ['alg', 'jwk']);
    expect(header['alg'], 'ES256');
    expect(header['jwk'], await rig.ambient.publicJwk());
    expect((header['jwk']! as Map).keys, ['crv', 'kty', 'x', 'y']);
    final claims = part(jws, 1);
    expect(claims.keys, [
      'iat',
      'exp',
      'jti',
      'mth',
      'pth',
      'qsh',
      'bdh',
      'aud',
    ]);
    expect(claims['exp'], (claims['iat']! as int) + 300);
    expect(claims['mth'], 'POST');
    expect(claims['pth'], '/orders/42');
    expect(claims['qsh'], hex(utf8.encode('page=2&sort=asc')));
    expect(claims['bdh'], hex(utf8.encode('{"a":1}')));
    expect(claims['aud'], audience);
    expect(claims['jti'], isA<String>());
  });

  test('qsh and bdh are left out when there is no query and no body', () async {
    final rig = Rig.create();
    await rig.enrol();
    await rig.send('/orders');
    final claims = part(rig.api.seen.single.signature!, 1);
    expect(claims.keys, ['iat', 'exp', 'jti', 'mth', 'pth', 'aud']);
    await rig.send('/orders', method: 'POST', body: const []);
    expect(part(rig.api.seen.last.signature!, 1).containsKey('bdh'), isFalse);
  });

  test('the method is upper-cased and an empty path is /', () async {
    final rig = Rig.create();
    await rig.enrol();
    await rig.transport.send(
      TransportRequest(method: 'get', uri: Uri.parse(audience)),
    );
    final claims = part(rig.api.seen.single.signature!, 1);
    expect(claims['mth'], 'GET');
    expect(claims['pth'], '/');
    rig.expectAllVerified();
  });

  test('every send has a jti no other send had', () async {
    final rig = Rig.create();
    await rig.enrol();
    for (var i = 0; i < 20; i++) {
      await rig.send('/orders');
    }
    expect(rig.api.verifiedJtis.toSet(), hasLength(20));
    // 128 bits, base64url without padding.
    expect(rig.api.verifiedJtis.first, hasLength(22));
  });

  test(
    'a streamed body is refused, clearly, before anything is sent',
    () async {
      final rig = Rig.create();
      await rig.enrol();
      final request = TransportRequest(
        method: 'POST',
        uri: Uri.parse('$audience/upload'),
        bodyStream: Stream.value([1, 2, 3]),
      );
      await expectLater(
        rig.transport.send(request),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'message',
            contains('streamed body cannot be signed'),
          ),
        ),
      );
      expect(rig.api.seen, isEmpty);
      // An empty stream, or a method with no body, is not a body.
      await rig.transport.send(
        TransportRequest(
          method: 'GET',
          uri: Uri.parse('$audience/orders'),
          bodyStream: const Stream.empty(),
          contentLength: 0,
        ),
      );
      rig.expectAllVerified();
    },
  );

  test(
    'the user-present key signs a request that asks for it, and prompts',
    () async {
      final rig = Rig.create();
      await rig.enrol();
      final before = rig.userPresent!.prompts;
      await rig.send(
        '/devices/revoke',
        method: 'POST',
        attributes: {
          DeviceSigner.roleAttribute: KeyRole.userPresent,
          DeviceSigner.reasonAttribute: 'Revoke this device',
        },
      );
      final sent = rig.api.seen.single;
      expect(rig.userPresent!.prompts, before + 1);
      expect(rig.userPresent!.lastReason, 'Revoke this device');
      expect(
        sent.attestation,
        rig.credential.attestation(KeyRole.userPresent)!.jws,
      );
      expect(
        part(sent.signature!, 0)['jwk'],
        await rig.userPresent!.publicJwk(),
      );
      expect(rig.ambient.signatures, 1, reason: 'only the enrolment challenge');
      rig.expectAllVerified();
    },
  );

  test('an ordinary request never prompts', () async {
    final rig = Rig.create();
    await rig.enrol();
    final before = rig.userPresent!.prompts;
    await rig.send('/orders');
    expect(rig.userPresent!.prompts, before);
  });

  test(
    'a user-present request on a device without that key is a clear StateError',
    () async {
      final rig = Rig.create(withUserPresent: false);
      await rig.enrol();
      expect(rig.credential.attestations.keys, [KeyRole.ambient]);
      await expectLater(
        rig.send(
          '/x',
          attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no such key'),
          ),
        ),
      );
      expect(rig.api.seen, isEmpty);
      expect(rig.state, isA<SignedIn>());
    },
  );

  test('a KeyRolePolicy picks the key', () async {
    final rig = Rig.create();
    await rig.enrol();
    final signer = DeviceSigner(
      keys: rig.backend.keys,
      profile: profile,
      policy: (request) => request.uri.path.startsWith('/sensitive')
          ? KeyRole.userPresent
          : KeyRole.ambient,
    );
    final session = rig.notifier.session!;
    final quiet = await signer.headers(session, rig.request('/orders'));
    final loud = await signer.headers(session, rig.request('/sensitive/x'));
    expect(
      quiet['X-Attestation'],
      rig.credential.attestation(KeyRole.ambient)!.jws,
    );
    expect(
      loud['X-Attestation'],
      rig.credential.attestation(KeyRole.userPresent)!.jws,
    );
  });

  test(
    'unsigned calls carry no headers at all, and are accepted whatever they answer',
    () async {
      final rig = Rig.create();
      await rig.enrol();
      final signer = DeviceSigner(
        keys: rig.backend.keys,
        profile: profile,
        unsignedPaths: ['/auth/enrol/begin'],
        unsigned: (r) => r.method == 'OPTIONS',
      );
      final session = rig.notifier.session!;
      expect(
        await signer.headers(
          session,
          rig.request('/auth/enrol/begin', method: 'POST'),
        ),
        isEmpty,
      );
      expect(
        await signer.headers(session, rig.request('/x', method: 'OPTIONS')),
        isEmpty,
      );
      expect(await signer.headers(session, rig.request('/x')), isNotEmpty);
      final verdict = signer.judge(
        session,
        rig.request('/auth/enrol/begin'),
        statusCode: 401,
        headers: const {},
        body: '{"error":"key_not_bound"}',
        retried: false,
      );
      expect(verdict, isA<Accept>());
    },
  );

  test('a lifetime of zero or over five minutes is refused', () {
    final keys = Rig.create().backend.keys;
    for (final lifetime in [Duration.zero, const Duration(minutes: 6)]) {
      expect(
        () => DeviceSigner(
          keys: keys,
          profile: DeviceSignatureProfile(
            audience: audience,
            lifetime: lifetime,
          ),
        ),
        throwsArgumentError,
      );
    }
    final short = DeviceSigner(
      keys: keys,
      profile: const DeviceSignatureProfile(
        audience: audience,
        lifetime: Duration(seconds: 30),
      ),
    );
    expect(short.profile.lifetime, const Duration(seconds: 30));
  });

  test('a custom profile changes the header names and the audience', () async {
    final rig = Rig.create();
    await rig.enrol();
    const custom = DeviceSignatureProfile(
      audience: 'urn:shop',
      signatureHeader: 'X-Sig',
      attestationHeader: 'X-Att',
    );
    final signer = DeviceSigner(keys: rig.backend.keys, profile: custom);
    final headers = await signer.headers(
      rig.notifier.session!,
      rig.request('/x'),
    );
    expect(headers.keys, ['X-Att', 'X-Sig']);
    expect(part(headers['X-Sig']!, 1)['aud'], 'urn:shop');
  });

  group('the default classifier', () {
    AuthVerdict judge(
      int status,
      String body, {
      KeyRole role = KeyRole.ambient,
    }) => webankRefusals(
      DeviceRefusal(
        role: role,
        statusCode: status,
        headers: const {},
        body: body,
        retried: false,
      ),
    );

    test(
      'renews on attestation_expired and device_not_active, with the key role',
      () {
        for (final code in ['attestation_expired', 'device_not_active']) {
          final verdict = judge(
            401,
            '{"error":"$code"}',
            role: KeyRole.userPresent,
          );
          expect(
            verdict,
            isA<Renew>().having((r) => r.hint, 'hint', KeyRole.userPresent),
          );
        }
      },
    );

    test(
      'ends the session as keyLost on key_not_bound, bad_jwk and missing_credential',
      () {
        for (final code in ['key_not_bound', 'bad_jwk', 'missing_credential']) {
          expect(
            judge(401, '{"error":"$code"}'),
            isA<SessionEnded>().having(
              (e) => e.reason,
              'reason',
              SignOutReason.keyLost,
            ),
          );
        }
      },
    );

    test('ends the session as revoked on 403 DEVICE_REVOKED', () {
      expect(
        judge(403, '{"error":"DEVICE_REVOKED"}'),
        isA<SessionEnded>().having(
          (e) => e.reason,
          'reason',
          SignOutReason.revoked,
        ),
      );
    });

    test('anything else is ambiguous: Accept', () {
      expect(judge(401, '{"error":"rate_limited"}'), isA<Accept>());
      expect(judge(401, 'not json'), isA<Accept>());
      expect(judge(401, ''), isA<Accept>());
      expect(judge(401, '[1]'), isA<Accept>());
      expect(judge(403, '{"error":"forbidden"}'), isA<Accept>());
      expect(judge(500, '{"error":"key_not_bound"}'), isA<Accept>());
      expect(judge(403, '{"error":"key_not_bound"}'), isA<Accept>());
    });

    test('a classifier of the app replaces it', () async {
      final rig = Rig.create();
      await rig.enrol();
      final signer = DeviceSigner(
        keys: rig.backend.keys,
        profile: profile,
        classify: (r) => r.statusCode == 418 ? const Renew() : const Accept(),
      );
      final session = rig.notifier.session!;
      expect(
        signer.judge(
          session,
          rig.request('/x'),
          statusCode: 418,
          headers: const {},
          body: null,
          retried: false,
        ),
        isA<Renew>(),
      );
    });
  });

  test('a Uint8List body is hashed as it is, byte for byte', () async {
    final rig = Rig.create();
    await rig.enrol();
    final cbor = Uint8List.fromList([0xa1, 0x61, 0x61, 0x01, 0xff, 0x00]);
    await rig.send('/cbor', method: 'PUT', body: cbor);
    expect(part(rig.api.seen.single.signature!, 1)['bdh'], hex(cbor));
    rig.expectAllVerified();
  });
}
