import 'dart:convert';
import 'dart:typed_data';

import 'package:device/api.dart';
import 'package:fespalier/fespalier.dart' show FieldErrors;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// "Your own server": the calls of the device ceremonies to the endpoints of lib/demo/demo_api.dart,
/// with their payloads. `fespalier_sign_keypair` knows the order of the legs, what is signed and
/// what is kept; it knows no URL, so this is the only place that does.
///
/// It sends through the transport it is given, which is `AuthConfig.transport`: the one with **no
/// session on it**, so the four legs of enrolment and renewal go out unsigned, by construction. A
/// 422 with `errors` is the `FieldErrors` a form shows under its field; a 403 is `AuthRejected`
/// (the server confirms this device is dead); anything else is "could not ask", and the session
/// stays.
///
/// Copy it and change the paths and the payloads.
final class ExampleDeviceServer implements DeviceAuthServer {
  /// The server's endpoints, reached through [transport].
  const ExampleDeviceServer(this.transport);

  /// What the requests go through: no session on it.
  final HttpTransport transport;

  @override
  Future<EnrolmentChallenge> beginEnrolment(EnrolmentStart start) async {
    final answer = await _post('/device/enrolments', {
      ...start.fields,
      'keys': {
        for (final entry in start.keys.entries) entry.key.name: entry.value,
      },
    });
    return EnrolmentChallenge(
      challenges: _byRole(answer['challenges']),
      data: {'enrolmentId': answer['enrolmentId']},
    );
  }

  @override
  Future<DeviceEnrolment> confirmEnrolment(
    EnrolmentChallenge challenge,
    Map<KeyRole, String> challengeSignatures,
    Object? proof,
  ) async {
    final answer = await _post(
      '/device/enrolments/${challenge.data['enrolmentId']}/confirm',
      {
        'otp': proof,
        'signatures': {
          for (final entry in challengeSignatures.entries)
            entry.key.name: entry.value,
        },
      },
    );
    final user = answer['user']! as Map<String, Object?>;
    return DeviceEnrolment(
      deviceId: answer['deviceId']! as String,
      attestations: {
        for (final entry in _byRole(answer['attestations']).entries)
          entry.key: Attestation.parse(entry.value),
      },
      user: AuthUser(id: user['id']! as String, name: user['name'] as String?),
    );
  }

  @override
  Future<RoleChallenge> beginRenewal(String deviceId, KeyRole role) async {
    final answer = await _post('/device/renewals', {
      'deviceId': deviceId,
      'role': role.name,
    });
    return RoleChallenge(
      role: role,
      challenge: answer['challenge']! as String,
      data: {'challengeId': answer['challengeId']},
    );
  }

  @override
  Future<Attestation> confirmRenewal(
    RoleChallenge challenge,
    String signature,
  ) async {
    final answer = await _post(
      '/device/renewals/${challenge.data['challengeId']}/confirm',
      {'signature': signature},
    );
    return Attestation.parse(answer['attestation']! as String);
  }

  /// `DELETE /devices/{id}`, signed by hand: this call does not go through `authTransport`, and
  /// `signer.signFor` signs it with the user-present key when the device has one (it prompts). A
  /// server that cannot be reached, or a refused prompt, throws, and the sign-out goes on.
  @override
  Future<void> revoke(DeviceCredential credential, DeviceSigner signer) async {
    final uri = api('/devices/${credential.deviceId}');
    final unsigned = TransportRequest(method: 'DELETE', uri: uri);
    final response = await transport.send(
      TransportRequest(
        method: 'DELETE',
        uri: uri,
        headers: await signer.signFor(credential, unsigned),
      ),
    );
    await response.bytes();
    if (response.statusCode >= 400) {
      throw ApiError(response.statusCode, 'the device was not revoked');
    }
  }

  Future<Map<String, Object?>> _post(String path, Object body) async {
    final response = await transport.send(
      TransportRequest(
        method: 'POST',
        uri: api(path),
        headers: const {'content-type': 'application/json'},
        body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      ),
    );
    final text = utf8.decode(await response.bytes());
    final json = text.isEmpty ? null : jsonDecode(text);
    final status = response.statusCode;
    if (status >= 200 && status < 300) return json! as Map<String, Object?>;
    if (status == 422 && json is Map<String, Object?>) {
      final errors = json['errors'];
      if (errors is Map<String, Object?>) {
        throw FieldErrors({
          for (final entry in errors.entries) entry.key: '${entry.value}',
        });
      }
    }
    // The server confirms this device is dead: the session is over.
    if (status == 403) throw const AuthRejected();
    throw ApiError(status, text);
  }

  Map<KeyRole, String> _byRole(Object? raw) => {
    for (final entry in (raw! as Map<String, Object?>).entries)
      KeyRole.values.byName(entry.key): entry.value! as String,
  };
}
