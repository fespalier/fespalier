// verifyDeviceSignature against real sends of the signer: it accepts them, and it refuses each
// way a request can be changed, replayed, aged or re-keyed. (b) of fespalier#267, for the
// request itself; the transports are exercised in the http and dio tests.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:fespalier_sign_keypair/verify.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// One real send, and what a server needs to check it.
final class Captured {
  Captured(
    this.rig,
    this.method,
    this.uri,
    this.headers,
    this.body,
    this.sentAt,
  );
  final Rig rig;
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List body;
  final DateTime sentAt;
}

Future<Captured> capture(
  Rig rig, {
  String path = '/orders/42?page=2',
  String method = 'POST',
  List<int> body = const [1, 2, 3],
}) async {
  await rig.send(path, method: method, body: body.isEmpty ? null : body);
  final seen = rig.api.seen.last;
  return Captured(
    rig,
    method,
    seen.request.uri,
    seen.request.headers,
    seen.body,
    DateTime.now(),
  );
}

Future<VerifiedDeviceRequest> check(
  Captured c, {
  String? method,
  Uri? uri,
  List<int>? body,
  bool noBody = false,
  Map<String, String>? headers,
  DeviceSignatureProfile prof = profile,
  Set<String>? seen,
  DateTime? now,
  List<Map<String, Object?>>? issuerKeys,
  Duration skew = const Duration(seconds: 30),
}) async => verifyDeviceSignature(
  method: method ?? c.method,
  uri: uri ?? c.uri,
  headers: headers ?? c.headers,
  body: noBody ? null : (body ?? c.body),
  profile: prof,
  issuerKeys: issuerKeys ?? await c.rig.server.issuerKeys,
  seenJtis: seen ?? <String>{},
  now: now ?? c.sentAt,
  skew: skew,
);

Matcher refusedWith(DeviceSignatureError error, {String? claim}) => throwsA(
  isA<DeviceSignatureInvalid>()
      .having((e) => e.error, 'error', error)
      .having((e) => e.claim, 'claim', claim),
);

void main() {
  late Rig rig;
  late Captured sent;

  setUp(() async {
    rig = Rig.create();
    await rig.enrol();
    sent = await capture(rig);
  });

  test('accepts a real send, and says who and which key', () async {
    final verified = await check(sent);
    expect(verified.subject, rig.server.user.id);
    expect(verified.deviceId, rig.credential.deviceId);
    expect(verified.jwk, await rig.ambient.publicJwk());
    expect(
      verified.thumbprint,
      rig.credential.attestation(KeyRole.ambient)!.jkt,
    );
    expect(verified.claims['mth'], 'POST');
  });

  test('accepts a send with no query and no body', () async {
    final c = await capture(
      rig,
      path: '/orders',
      method: 'GET',
      body: const [],
    );
    await check(c, noBody: true);
    await check(c, body: const [], seen: {});
  });

  test(
    'accepts a send within the skew either side, and refuses it outside',
    () async {
      final iat =
          jsonDecode(
                utf8.decode(
                  base64UrlDecodeLoose(
                    sent.headers['X-Signature']!.split('.')[1],
                  ),
                ),
              )
              as Map<String, Object?>;
      final issued = DateTime.fromMillisecondsSinceEpoch(
        (iat['iat']! as int) * 1000,
        isUtc: true,
      );
      await check(sent, now: issued.subtract(const Duration(seconds: 29)));
      await check(sent, now: issued.add(const Duration(seconds: 300 + 29)));
      await expectLater(
        check(sent, now: issued.subtract(const Duration(seconds: 31))),
        refusedWith(DeviceSignatureError.signatureExpired),
      );
      await expectLater(
        check(sent, now: issued.add(const Duration(seconds: 300 + 30))),
        refusedWith(DeviceSignatureError.signatureExpired),
      );
      // 340 s on is past exp + 30 s, but inside exp + 60 s: the skew is the caller's.
      await check(
        sent,
        now: issued.add(const Duration(seconds: 340)),
        skew: const Duration(seconds: 60),
      );
    },
  );

  group('refuses a request that was changed', () {
    test('the body', () async {
      await expectLater(
        check(sent, body: [1, 2, 4]),
        refusedWith(DeviceSignatureError.mismatch, claim: 'bdh'),
      );
      await expectLater(
        check(sent, body: [1, 2, 3, 4]),
        refusedWith(DeviceSignatureError.mismatch, claim: 'bdh'),
      );
      await expectLater(
        check(sent, noBody: true),
        refusedWith(DeviceSignatureError.mismatch, claim: 'bdh'),
      );
    });

    test('a body that was not signed', () async {
      final c = await capture(
        rig,
        path: '/orders',
        method: 'POST',
        body: const [],
      );
      await expectLater(
        check(c, body: [9]),
        refusedWith(DeviceSignatureError.mismatch, claim: 'bdh'),
      );
    });

    test('the query', () async {
      await expectLater(
        check(sent, uri: sent.uri.replace(query: 'page=3')),
        refusedWith(DeviceSignatureError.mismatch, claim: 'qsh'),
      );
      await expectLater(
        check(sent, uri: sent.uri.replace(query: '')),
        refusedWith(DeviceSignatureError.mismatch, claim: 'qsh'),
      );
      await expectLater(
        check(sent, uri: sent.uri.replace(query: 'page=2&x=1')),
        refusedWith(DeviceSignatureError.mismatch, claim: 'qsh'),
      );
    });

    test('a query that was not signed', () async {
      final c = await capture(
        rig,
        path: '/orders',
        method: 'GET',
        body: const [],
      );
      await expectLater(
        check(c, noBody: true, uri: c.uri.replace(query: 'admin=1')),
        refusedWith(DeviceSignatureError.mismatch, claim: 'qsh'),
      );
    });

    test('the path', () async {
      await expectLater(
        check(sent, uri: sent.uri.replace(path: '/orders/43')),
        refusedWith(DeviceSignatureError.mismatch, claim: 'pth'),
      );
    });

    test('the method', () async {
      await expectLater(
        check(sent, method: 'PUT'),
        refusedWith(DeviceSignatureError.mismatch, claim: 'mth'),
      );
      await expectLater(
        check(sent, method: 'DELETE'),
        refusedWith(DeviceSignatureError.mismatch, claim: 'mth'),
      );
    });

    test('the audience', () async {
      await expectLater(
        check(
          sent,
          prof: const DeviceSignatureProfile(
            audience: 'https://other.example.com',
          ),
        ),
        refusedWith(DeviceSignatureError.mismatch, claim: 'aud'),
      );
    });
  });

  group('single use', () {
    test('a reused jti is a replay', () async {
      final seen = <String>{};
      await check(sent, seen: seen);
      await expectLater(
        check(sent, seen: seen),
        refusedWith(DeviceSignatureError.replay),
      );
    });

    test('a refused request does not burn its jti', () async {
      final seen = <String>{};
      await expectLater(
        check(sent, body: [0], seen: seen),
        refusedWith(DeviceSignatureError.mismatch, claim: 'bdh'),
      );
      expect(seen, isEmpty);
      await check(sent, seen: seen);
      expect(seen, hasLength(1));
    });

    test('two real sends have two jtis', () async {
      final again = await capture(rig);
      final seen = <String>{};
      await check(sent, seen: seen);
      await check(again, seen: seen);
      expect(seen, hasLength(2));
    });
  });

  group('refuses an expired signature, attestation or lifetime', () {
    test('the signature, an hour later', () async {
      await expectLater(
        check(sent, now: sent.sentAt.add(const Duration(hours: 1))),
        refusedWith(DeviceSignatureError.signatureExpired),
      );
    });

    test('the attestation, a day later', () async {
      await expectLater(
        check(sent, now: sent.sentAt.add(const Duration(hours: 25))),
        refusedWith(DeviceSignatureError.attestationExpired),
      );
    });

    test('a signature that lives longer than five minutes', () async {
      final keys = await rig.server.issuerKeys;
      final jwk = await rig.ambient.publicJwk();
      final iat = sent.sentAt.millisecondsSinceEpoch ~/ 1000;
      final jws = await compactJws(
        {'alg': 'ES256', 'jwk': jwk},
        {
          'iat': iat,
          'exp': iat + 600,
          'jti': 'long',
          'mth': 'GET',
          'pth': '/x',
          'aud': audience,
        },
        rig.ambient,
      );
      final headers = {
        'X-Attestation': rig.credential.attestation(KeyRole.ambient)!.jws,
        'X-Signature': jws,
      };
      expect(
        () => verifyDeviceSignature(
          method: 'GET',
          uri: Uri.parse('$audience/x'),
          headers: headers,
          profile: profile,
          issuerKeys: keys,
          seenJtis: {},
          now: sent.sentAt,
        ),
        refusedWith(DeviceSignatureError.lifetimeTooLong),
      );
    });
  });

  group('refuses a key that is not the attested one', () {
    test('a jwk that is not cnf.jkt', () async {
      final intruder = FakeKeypairSigner(seed: 'an intruder');
      final signer = DeviceSigner(
        keys: DeviceKeys(ambient: intruder),
        profile: profile,
      );
      // The intruder signs a perfectly good request, and presents the victim's attestation.
      final keys = await rig.server.issuerKeys;
      final headers = await signer.signFor(
        rig.credential,
        rig.request('/orders'),
      );
      expect(
        () => verifyDeviceSignature(
          method: 'GET',
          uri: Uri.parse('$audience/orders'),
          headers: headers,
          profile: profile,
          issuerKeys: keys,
          seenJtis: {},
        ),
        refusedWith(DeviceSignatureError.keyNotBound),
      );
    });

    test('a jwk that is not a public P-256 key', () async {
      final header = base64UrlNoPad(
        utf8.encode(
          jsonEncode({
            'alg': 'ES256',
            'jwk': {'kty': 'EC', 'crv': 'P-256', 'x': 'AAAA', 'y': 'AAAA'},
          }),
        ),
      );
      final headers = {
        'X-Attestation': sent.headers['X-Attestation']!,
        'X-Signature': '$header.e30.AAAA',
      };
      await expectLater(
        check(sent, headers: headers),
        refusedWith(DeviceSignatureError.badJwk),
      );
    });

    test('a signature that does not verify', () async {
      final parts = sent.headers['X-Signature']!.split('.');
      final other = base64UrlNoPad(Uint8List(64)..[0] = 1);
      final headers = {
        'X-Attestation': sent.headers['X-Attestation']!,
        'X-Signature': '${parts[0]}.${parts[1]}.$other',
      };
      await expectLater(
        check(sent, headers: headers),
        refusedWith(DeviceSignatureError.badSignature),
      );
    });

    test('claims that were edited after signing', () async {
      final parts = sent.headers['X-Signature']!.split('.');
      final claims =
          jsonDecode(utf8.decode(base64UrlDecodeLoose(parts[1])))
              as Map<String, Object?>;
      claims['mth'] = 'GET';
      final edited = base64UrlNoPad(utf8.encode(jsonEncode(claims)));
      final headers = {
        'X-Attestation': sent.headers['X-Attestation']!,
        'X-Signature': '${parts[0]}.$edited.${parts[2]}',
      };
      await expectLater(
        check(sent, method: 'GET', headers: headers),
        refusedWith(DeviceSignatureError.badSignature),
      );
    });
  });

  group('refuses an attestation the issuer did not sign', () {
    test('another issuer key', () async {
      final other = FakeDeviceAuthServer(issuerSeed: 'another issuer');
      await expectLater(
        check(sent, issuerKeys: await other.issuerKeys),
        refusedWith(DeviceSignatureError.badAttestation),
      );
      await expectLater(
        check(sent, issuerKeys: const []),
        refusedWith(DeviceSignatureError.badAttestation),
      );
    });

    test('a tampered attestation', () async {
      final parts = sent.headers['X-Attestation']!.split('.');
      final claims =
          jsonDecode(utf8.decode(base64UrlDecodeLoose(parts[1])))
              as Map<String, Object?>;
      claims['sub'] = 'someone-else';
      final headers = {
        'X-Signature': sent.headers['X-Signature']!,
        'X-Attestation':
            '${parts[0]}.${base64UrlNoPad(utf8.encode(jsonEncode(claims)))}.${parts[2]}',
      };
      await expectLater(
        check(sent, headers: headers),
        refusedWith(DeviceSignatureError.badAttestation),
      );
    });

    test('garbage', () async {
      for (final garbage in ['x', 'a.b', 'a.b.c', '..']) {
        final headers = {
          'X-Signature': sent.headers['X-Signature']!,
          'X-Attestation': garbage,
        };
        await expectLater(
          check(sent, headers: headers),
          refusedWith(DeviceSignatureError.badAttestation),
          reason: garbage,
        );
      }
      await expectLater(
        check(
          sent,
          headers: {
            'X-Attestation': sent.headers['X-Attestation']!,
            'X-Signature': 'x.y',
          },
        ),
        refusedWith(DeviceSignatureError.badSignature),
      );
    });
  });

  group('missing headers', () {
    test('either one', () async {
      await expectLater(
        check(sent, headers: {'X-Signature': sent.headers['X-Signature']!}),
        refusedWith(DeviceSignatureError.missingCredential),
      );
      await expectLater(
        check(sent, headers: {'X-Attestation': sent.headers['X-Attestation']!}),
        refusedWith(DeviceSignatureError.missingCredential),
      );
      await expectLater(
        check(sent, headers: {}),
        refusedWith(DeviceSignatureError.missingCredential),
      );
    });

    test(
      'header names are matched case-insensitively and follow the profile',
      () async {
        await check(
          sent,
          headers: {
            'x-attestation': sent.headers['X-Attestation']!,
            'X-SIGNATURE': sent.headers['X-Signature']!,
          },
        );
        const custom = DeviceSignatureProfile(
          audience: audience,
          signatureHeader: 'X-Sig',
          attestationHeader: 'X-Att',
        );
        await expectLater(
          check(sent, prof: custom),
          refusedWith(DeviceSignatureError.missingCredential),
        );
      },
    );
  });

  group('the codes match the client classifier', () {
    AuthVerdict classify(DeviceSignatureError error, {int status = 401}) =>
        webankRefusals(
          DeviceRefusal(
            role: KeyRole.ambient,
            statusCode: status,
            headers: const {},
            body: jsonEncode({'error': error.code}),
            retried: false,
          ),
        );

    test('renewable, dead and ambiguous', () {
      expect(classify(DeviceSignatureError.attestationExpired), isA<Renew>());
      for (final dead in [
        DeviceSignatureError.keyNotBound,
        DeviceSignatureError.badJwk,
        DeviceSignatureError.missingCredential,
      ]) {
        expect(
          classify(dead),
          isA<SessionEnded>().having(
            (e) => e.reason,
            'reason',
            SignOutReason.keyLost,
          ),
          reason: dead.code,
        );
      }
      for (final other in [
        DeviceSignatureError.badSignature,
        DeviceSignatureError.signatureExpired,
        DeviceSignatureError.replay,
        DeviceSignatureError.mismatch,
        DeviceSignatureError.badAttestation,
        DeviceSignatureError.lifetimeTooLong,
      ]) {
        expect(classify(other), isA<Accept>(), reason: other.code);
      }
    });

    test('the wire names', () {
      expect(DeviceSignatureError.values.map((e) => e.code), [
        'missing_credential',
        'bad_attestation',
        'attestation_expired',
        'bad_jwk',
        'key_not_bound',
        'bad_signature',
        'signature_expired',
        'lifetime_too_long',
        'mismatch',
        'replay',
      ]);
      expect(
        const DeviceSignatureInvalid(
          DeviceSignatureError.replay,
          'm',
        ).toString(),
        'DeviceSignatureInvalid: replay: m',
      );
    });
  });
}
