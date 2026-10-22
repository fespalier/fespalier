/// Fakes for tests of an app or a package built on `fespalier_sign_keypair` (since 0.21.0): a
/// [FakeDeviceAuthServer] that plays the app's enrolment and renewal endpoints, with an issuer key
/// of its own, so the attestations it hands out verify with `verifyDeviceSignature`.
///
/// Everything is deterministic and reads `clock.now()`, which a test's fake clock moves; nothing
/// waits for real time. Pair it with `FakeKeypairSigner` (`package:fespalier_keypair/testing.dart`)
/// for the device's keys.
library;

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart' show FieldErrors;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_keypair/verify.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'fespalier_sign_keypair.dart';

/// A device-auth server with no network (since 0.21.0): it checks the one-time code, verifies each
/// challenge signature against the key the device registered, and issues attestations signed by a
/// test issuer key ([issuerKeys] are the JWKs to hand to `verifyDeviceSignature`).
///
/// A test steers it with fields, then looks at the counters and logs:
///
/// * [otp] is the code `confirmEnrolment` wants (a wrong one is a `FieldErrors`);
/// * [attestationLifetime] is how long what it issues lives, read against `clock.now()`;
/// * [beginEnrolmentError], [confirmEnrolmentError], [renewalError] and [revokeError] are thrown
///   by the next call(s) until set back to null: `AuthRejected()` is a 403 (the device is dead),
///   a `TransportUnsent()` is being offline;
/// * [renewalGate] holds `beginRenewal` until it completes, to keep a renewal in flight;
/// * [revokeDevice] makes the server refuse that device's renewals, as a revoked one is.
final class FakeDeviceAuthServer implements DeviceAuthServer {
  /// A server whose issuer key comes from [issuerSeed] (so its JWK is the same on every run).
  FakeDeviceAuthServer({
    this.otp = '123456',
    this.attestationLifetime = const Duration(hours: 24),
    this.user = const AuthUser(id: 'user-1'),
    this.issuerName = 'https://issuer.example.com',
    String issuerSeed = 'fespalier_sign_keypair fake issuer',
  }) : _issuer = FakeKeypairSigner(keyId: 'issuer', seed: issuerSeed);

  /// The one-time code `confirmEnrolment` accepts.
  String otp;

  /// How long an attestation it issues lives.
  Duration attestationLifetime;

  /// Who a device enrols as.
  AuthUser user;

  /// The `iss` claim of what it issues.
  final String issuerName;

  final FakeKeypairSigner _issuer;

  /// Thrown by `beginEnrolment` until set back to null.
  Object? beginEnrolmentError;

  /// Thrown by `confirmEnrolment` until set back to null.
  Object? confirmEnrolmentError;

  /// Thrown by `beginRenewal` until set back to null.
  Object? renewalError;

  /// Thrown by `revoke` (after it signed its request) until set back to null.
  Object? revokeError;

  /// While set, `beginRenewal` waits for it.
  Completer<void>? renewalGate;

  /// How many enrolments were confirmed.
  int enrolments = 0;

  /// The role of each `beginRenewal`, in order.
  final List<KeyRole> renewalRequests = [];

  /// How many renewals were confirmed.
  int renewals = 0;

  /// The credentials `revoke` was called with, in order.
  final List<DeviceCredential> revocations = [];

  /// The role of the key `revoke`'s request was signed with, in order.
  final List<KeyRole> revokeSignedWith = [];

  /// The headers of each request `revoke` signed, in order.
  final List<Map<String, String>> revokeHeaders = [];

  /// The enrolments seen by `beginEnrolment`: the fields the app sent, in order.
  final List<Map<String, Object?>> startedWith = [];

  final Map<String, Map<KeyRole, Map<String, String>>> _devices = {};
  final Set<String> _revoked = {};
  final Map<String, Map<KeyRole, Map<String, String>>> _pending = {};
  int _challenges = 0;
  int _devicesIssued = 0;

  /// The issuer's public key, for `verifyDeviceSignature(issuerKeys: ...)`.
  Future<List<Map<String, Object?>>> get issuerKeys async => [
    await _issuer.publicJwk(),
  ];

  /// Makes the server refuse [deviceId] from now on, as one that was revoked: a renewal is
  /// answered with an `AuthRejected`.
  void revokeDevice(String deviceId) => _revoked.add(deviceId);

  /// The ids of the devices that enrolled, in order.
  List<String> get devices => _devices.keys.toList();

  /// An attestation for [jwk], issued now by the test issuer, for the device [deviceId]. Public so
  /// a test can mint what the server would not (one for another key, an expired one with a
  /// negative [lifetime]).
  Future<Attestation> issue({
    required String deviceId,
    required Map<String, String> jwk,
    Duration? lifetime,
    String? subject,
  }) async {
    final now = clock.now().millisecondsSinceEpoch ~/ 1000;
    final jws = await compactJws(
      const <String, Object?>{'alg': 'ES256', 'typ': 'JWT'},
      <String, Object?>{
        'iss': issuerName,
        'sub': subject ?? user.id,
        'did': deviceId,
        'iat': now,
        'exp': now + (lifetime ?? attestationLifetime).inSeconds,
        'cnf': <String, Object?>{'jkt': jwkThumbprint(jwk)},
        'status': 'active',
      },
      _issuer,
    );
    return Attestation.parse(jws);
  }

  @override
  Future<EnrolmentChallenge> beginEnrolment(EnrolmentStart start) async {
    final error = beginEnrolmentError;
    if (error != null) throw error;
    startedWith.add(start.fields);
    final id = 'enrolment-${_pending.length + 1}';
    _pending[id] = {
      for (final entry in start.keys.entries) entry.key: entry.value,
    };
    return EnrolmentChallenge(
      challenges: {
        for (final role in start.keys.keys)
          role: 'challenge-${++_challenges}-${role.name}',
      },
      data: {'enrolmentId': id},
    );
  }

  @override
  Future<DeviceEnrolment> confirmEnrolment(
    EnrolmentChallenge challenge,
    Map<KeyRole, String> challengeSignatures,
    Object? proof,
  ) async {
    final error = confirmEnrolmentError;
    if (error != null) throw error;
    if (proof != otp) {
      throw const FieldErrors({'otp': 'wrong code'});
    }
    final keys = _pending[challenge.data['enrolmentId']];
    if (keys == null) throw const AuthRejected('unknown_enrolment');
    for (final entry in keys.entries) {
      final signature = challengeSignatures[entry.key];
      if (signature == null ||
          !_signsChallenge(
            entry.value,
            signature,
            challenge.challenges[entry.key],
          )) {
        throw const AuthRejected('invalid_signature');
      }
    }
    final deviceId = 'device-${++_devicesIssued}';
    _devices[deviceId] = keys;
    enrolments++;
    return DeviceEnrolment(
      deviceId: deviceId,
      attestations: {
        for (final entry in keys.entries)
          entry.key: await issue(deviceId: deviceId, jwk: entry.value),
      },
      user: user,
    );
  }

  @override
  Future<RoleChallenge> beginRenewal(String deviceId, KeyRole role) async {
    renewalRequests.add(role);
    await renewalGate?.future;
    final error = renewalError;
    if (error != null) throw error;
    if (_revoked.contains(deviceId) || !_devices.containsKey(deviceId)) {
      throw const AuthRejected('device_revoked');
    }
    return RoleChallenge(
      role: role,
      challenge: 'renewal-${++_challenges}-${role.name}',
      data: {'deviceId': deviceId},
    );
  }

  @override
  Future<Attestation> confirmRenewal(
    RoleChallenge challenge,
    String signature,
  ) async {
    final deviceId = challenge.data['deviceId'] as String?;
    final jwk = _devices[deviceId]?[challenge.role];
    if (deviceId == null || jwk == null || _revoked.contains(deviceId)) {
      throw const AuthRejected('device_revoked');
    }
    if (!_signsChallenge(jwk, signature, challenge.challenge)) {
      throw const AuthRejected('invalid_signature');
    }
    renewals++;
    return issue(deviceId: deviceId, jwk: jwk);
  }

  @override
  Future<void> revoke(DeviceCredential credential, DeviceSigner signer) async {
    revocations.add(credential);
    final request = TransportRequest(
      method: 'DELETE',
      uri: Uri.parse('https://api.example.com/devices/${credential.deviceId}'),
    );
    // The role the signer's policy picks is the one that signs (and prompts).
    revokeSignedWith.add(signer.policy(request));
    revokeHeaders.add(await signer.signFor(credential, request));
    final error = revokeError;
    if (error != null) throw error;
    _revoked.add(credential.deviceId);
  }

  /// Whether [signature] is a compact JWS `{alg: ES256}` over `{"challenge": [challenge]}` by
  /// the key [jwk].
  bool _signsChallenge(
    Map<String, String> jwk,
    String signature,
    String? challenge,
  ) {
    final parts = signature.split('.');
    if (parts.length != 3 || challenge == null) return false;
    try {
      final header = jsonDecode(utf8.decode(base64UrlDecodeLoose(parts[0])));
      final payload = jsonDecode(utf8.decode(base64UrlDecodeLoose(parts[1])));
      return header is Map<String, Object?> &&
          header['alg'] == 'ES256' &&
          payload is Map<String, Object?> &&
          payload['challenge'] == challenge &&
          verifyEs256(
            jwk,
            utf8.encode('${parts[0]}.${parts[1]}'),
            base64UrlDecodeLoose(parts[2]),
          );
    } on FormatException {
      return false;
    }
  }
}
