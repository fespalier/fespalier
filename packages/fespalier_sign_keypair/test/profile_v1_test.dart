// Authkestra's device-signature profile v1 (RFC-014): its conformance vectors, copied into
// test/fixtures/devsig-profile-v1/ at the commit PIN names, run through verifyDeviceSignature,
// and its refusal table run through the client's classifier. Refresh the copy with
// tool/refresh-devsig-vectors.sh; never edit it.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/verify.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'test/fixtures/devsig-profile-v1';

/// A replay store that cannot be reached: every write fails.
final class _UnreachableStore extends SetBase<String> {
  @override
  bool add(String value) => throw StateError('the replay store is down');

  @override
  bool contains(Object? element) => false;

  @override
  Iterator<String> get iterator => const <String>[].iterator;

  @override
  int get length => 0;

  @override
  String? lookup(Object? element) => null;

  @override
  bool remove(Object? value) => false;

  @override
  Set<String> toSet() => <String>{};
}

Map<String, String> _pin() => {
  for (final line in File('$_dir/PIN').readAsLinesSync())
    if (!line.startsWith('#') && line.contains(': '))
      line.substring(0, line.indexOf(': ')): line.substring(
        line.indexOf(': ') + 2,
      ),
};

void main() {
  final file = File('$_dir/vectors.json');
  final vectors = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  final verifier = vectors['verifier']! as Map<String, Object?>;
  final cases = (vectors['vectors']! as List<Object?>)
      .cast<Map<String, Object?>>();
  List<String> strings(Object? list) => (list! as List<Object?>).cast<String>();

  final profile = DeviceSignatureProfile(
    audience: verifier['audience']! as String,
    signatureHeader: verifier['signature_header']! as String,
    attestationHeader: verifier['attestation_header']! as String,
  );
  final issuerKeys = [
    for (final key in vectors['issuer_keys']! as List<Object?>)
      ((key! as Map<String, Object?>)['jwk']! as Map<String, Object?>),
  ];

  test('the copy is the pinned one, byte for byte', () {
    final pin = _pin();
    expect(pin['repository'], 'https://github.com/Authkestra/authkestra');
    expect(pin['path'], 'conformance/devsig-profile-v1/vectors.json');
    expect(pin['commit'], matches(RegExp(r'^[0-9a-f]{40}$')));
    expect(sha256.convert(file.readAsBytesSync()).toString(), pin['sha256']);
  });

  test('the vectors are the ones this test was written for', () {
    expect(cases, hasLength(44));
    expect(cases.where((v) => v['required'] == true), hasLength(43));
    expect(verifier['clock_skew_secs'], 30);
    expect(verifier['max_signature_lifetime_secs'], 300);
  });

  for (final vector in cases) {
    final id = vector['id']! as String;
    final required = vector['required']! as bool;
    test('${required ? 'required' : 'optional'}: $id', () {
      final request = vector['request']! as Map<String, Object?>;
      final replay = vector['replay']! as Map<String, Object?>;
      final expected = vector['expect']! as Map<String, Object?>;
      final query = request['query'] as String?;
      final body = request['body'] as String?;
      final seen = replay['store'] == 'unavailable'
          ? _UnreachableStore()
          : strings(replay['seen_jtis']).toSet();

      VerifiedDeviceRequest run() => verifyDeviceSignature(
        method: request['method']! as String,
        uri: Uri.parse(
          '${profile.audience}${request['path']}${query == null ? '' : '?$query'}',
        ),
        headers: (request['headers']! as Map<String, Object?>).map(
          (name, value) => MapEntry(name, value! as String),
        ),
        body: body == null ? null : utf8.encode(body),
        profile: profile,
        issuerKeys: issuerKeys,
        trustedIssuers: strings(verifier['trusted_issuers']),
        issuerAlgorithms: strings(verifier['attestation_algs']).toSet(),
        deviceAlgorithms: strings(verifier['device_algs']).toSet(),
        skew: Duration(seconds: verifier['clock_skew_secs']! as int),
        maxLifetime: Duration(
          seconds: verifier['max_signature_lifetime_secs']! as int,
        ),
        seenJtis: seen,
        now: DateTime.fromMillisecondsSinceEpoch(
          (vector['now']! as int) * 1000,
          isUtc: true,
        ),
      );

      if (expected['outcome'] == 'accept') {
        final verified = run();
        expect(verified.subject, expected['sub']);
        expect(verified.deviceId, expected['did']);
        expect(verified.thumbprint, expected['jkt']);
        expect(
          verified.role,
          expected['role'] == 'user_present'
              ? KeyRole.userPresent
              : KeyRole.ambient,
        );
        expect(seen, contains(verified.jti));
        return;
      }
      final DeviceSignatureInvalid refused;
      try {
        run();
        fail('$id was accepted; expected ${expected['error']}');
      } on DeviceSignatureInvalid catch (e) {
        refused = e;
      }
      expect(refused.code, expected['error']);
      expect(refused.statusCode, expected['status']);
      expect(jsonDecode(refused.body), expected['body']);
      expect(refused.headers['content-type'], 'application/json');
      expect(refused.headers['www-authenticate'], expected['www_authenticate']);
    });
  }

  // Each accepted vector with one byte of a signature changed: proves that each algorithm path
  // (ES256, EdDSA and RS256 issuers, ES256 and EdDSA devices) really verifies.
  for (final vector in cases.where(
    (v) => (v['expect']! as Map<String, Object?>)['outcome'] == 'accept',
  )) {
    test('tampered: ${vector['id']}', () {
      final request = vector['request']! as Map<String, Object?>;
      final headers = (request['headers']! as Map<String, Object?>).map(
        (name, value) => MapEntry(name, value! as String),
      );
      String tamper(String jws) {
        final parts = jws.split('.');
        final signature = base64UrlDecodeLoose(parts[2]);
        signature[signature.length ~/ 2] ^= 0x01;
        return '${parts[0]}.${parts[1]}.${base64UrlNoPad(signature)}';
      }

      final query = request['query'] as String?;
      final body = request['body'] as String?;
      DeviceSignatureError refusal(Map<String, String> headers) {
        try {
          verifyDeviceSignature(
            method: request['method']! as String,
            uri: Uri.parse(
              '${profile.audience}${request['path']}${query == null ? '' : '?$query'}',
            ),
            headers: headers,
            body: body == null ? null : utf8.encode(body),
            profile: profile,
            issuerKeys: issuerKeys,
            trustedIssuers: strings(verifier['trusted_issuers']),
            deviceAlgorithms: strings(verifier['device_algs']).toSet(),
            seenJtis: {},
            now: DateTime.fromMillisecondsSinceEpoch(
              (vector['now']! as int) * 1000,
              isUtc: true,
            ),
          );
        } on DeviceSignatureInvalid catch (e) {
          return e.error;
        }
        fail('accepted');
      }

      expect(
        refusal({
          ...headers,
          'X-Attestation': tamper(headers['X-Attestation']!),
        }),
        DeviceSignatureError.badAttestation,
      );
      expect(
        refusal({...headers, 'X-Signature': tamper(headers['X-Signature']!)}),
        DeviceSignatureError.badSignature,
      );
    });
  }

  group('the refusal table', () {
    final table = (vectors['refusals']! as List<Object?>)
        .cast<Map<String, Object?>>();

    test('every code has its status, its challenge and its client action', () {
      expect(
        DeviceRefusals.statuses.keys.toSet(),
        table.map((r) => r['error']).toSet(),
      );
      for (final row in table) {
        final code = row['error']! as String;
        final status = row['status']! as int;
        expect(DeviceRefusals.statuses[code], status, reason: code);
        expect(
          DeviceRefusals.headers(
            code,
            statusCode: status,
          ).containsKey('www-authenticate'),
          row['www_authenticate'],
          reason: code,
        );
        expect(
          DeviceRefusals.actionOf(status, code).name,
          switch (row['client_action']) {
            'key_lost' => 'keyLost',
            'step_up' => 'stepUp',
            final String other => other,
            _ => throw StateError('$row'),
          },
          reason: code,
        );
      }
    });

    AuthVerdict classify(
      int status,
      String? body, {
      Map<String, String> headers = const {},
    }) => webankRefusals(
      DeviceRefusal(
        role: KeyRole.userPresent,
        statusCode: status,
        headers: headers,
        body: body,
        retried: false,
      ),
    );

    test('webankRefusals reads every row as the profile says', () {
      for (final row in table) {
        final code = row['error']! as String;
        final verdict = classify(
          row['status']! as int,
          DeviceRefusals.body(code),
        );
        final expected = switch (row['client_action']) {
          'renew' => isA<Renew>().having(
            (r) => r.hint,
            'hint',
            KeyRole.userPresent,
          ),
          'key_lost' => isA<SessionEnded>().having(
            (s) => s.reason,
            'reason',
            SignOutReason.keyLost,
          ),
          'revoked' => isA<SessionEnded>().having(
            (s) => s.reason,
            'reason',
            SignOutReason.revoked,
          ),
          // Step-up is the signer's (DeviceRefusal.isStepUp), before it asks the classifier.
          _ => isA<Accept>(),
        };
        expect(verdict, expected, reason: code);
      }
    });

    test('a code at another status is ambiguous', () {
      expect(
        classify(403, DeviceRefusals.body('key_not_bound')),
        isA<Accept>(),
      );
      expect(
        classify(401, DeviceRefusals.body('device_revoked')),
        isA<Accept>(),
      );
      expect(
        classify(500, DeviceRefusals.body('attestation_expired')),
        isA<Accept>(),
      );
    });

    test('the legacy names are still read', () {
      final aliases = (vectors['legacy_aliases']! as Map<String, Object?>).keys;
      expect(aliases.toSet(), {'replay', 'mismatch', 'DEVICE_REVOKED'});
      expect(
        classify(403, jsonEncode({'error': 'DEVICE_REVOKED'})),
        isA<SessionEnded>().having(
          (s) => s.reason,
          'reason',
          SignOutReason.revoked,
        ),
      );
      expect(classify(401, jsonEncode({'error': 'replay'})), isA<Accept>());
      expect(classify(401, jsonEncode({'error': 'mismatch'})), isA<Accept>());
      expect(DeviceRefusals.canonical('replay'), 'replay_detected');
      expect(DeviceRefusals.canonical('DEVICE_REVOKED'), 'device_revoked');
    });

    test('the challenge is read when the body says nothing', () {
      for (final body in [null, '', '\u{a1}cbor', '{"code":"x"}']) {
        expect(
          classify(
            401,
            body,
            headers: {
              'www-authenticate': DeviceRefusals.challenge(
                'attestation_expired',
              ),
            },
          ),
          isA<Renew>(),
          reason: body,
        );
      }
      // The body wins over the challenge, and another scheme's error is not read.
      expect(
        classify(
          401,
          DeviceRefusals.body('replay_detected'),
          headers: {
            'www-authenticate': DeviceRefusals.challenge('key_not_bound'),
          },
        ),
        isA<Accept>(),
      );
      expect(
        classify(
          401,
          null,
          headers: {'www-authenticate': 'Bearer error="key_not_bound"'},
        ),
        isA<Accept>(),
      );
    });
  });
}
