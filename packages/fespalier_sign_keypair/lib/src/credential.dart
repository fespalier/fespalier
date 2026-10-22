import 'package:collection/collection.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';

import 'attestation.dart';

/// What proves a device session (since 0.21.0): the device id and one [Attestation] per key role.
/// No token: an attestation is useless without a signature from the key it is bound to.
///
/// [expiresAt] is the ambient attestation's: it is the one that decides when the core renews. The
/// user-present attestation renews lazily, when a server refuses it. It is [renewable] with no end
/// ([renewableUntil] is null): the device key renews it, as long as the server allows.
///
/// The store keeps the attestations' JWS only (`{"deviceId", "attestations": {"ambient": "..."}}`);
/// the dates and thumbprints are read from them again, so they cannot disagree with them.
final class DeviceCredential implements SessionCredential {
  /// A credential for [deviceId] with [attestations]. The ambient role must be there.
  DeviceCredential({
    required this.deviceId,
    required Map<KeyRole, Attestation> attestations,
  }) : attestations = Map<KeyRole, Attestation>.unmodifiable(attestations) {
    if (!attestations.containsKey(KeyRole.ambient)) {
      throw ArgumentError.value(
        attestations.keys.toList(),
        'attestations',
        'a device credential needs an ambient attestation',
      );
    }
  }

  /// Reads what [toJson] wrote. Throws a [FormatException] on anything else.
  factory DeviceCredential.fromJson(Map<String, Object?> json) {
    final deviceId = json['deviceId'];
    final raw = json['attestations'];
    if (deviceId is! String || raw is! Map<String, Object?>) {
      throw const FormatException(
        'fespalier_sign_keypair: a stored device credential is malformed',
      );
    }
    final attestations = <KeyRole, Attestation>{};
    for (final entry in raw.entries) {
      final role = KeyRole.values.asNameMap()[entry.key];
      final jws = entry.value;
      if (role == null || jws is! String) {
        throw const FormatException(
          'fespalier_sign_keypair: a stored attestation is malformed',
        );
      }
      attestations[role] = Attestation.parse(jws);
    }
    if (!attestations.containsKey(KeyRole.ambient)) {
      throw const FormatException(
        'fespalier_sign_keypair: a stored device credential has no ambient attestation',
      );
    }
    return DeviceCredential(deviceId: deviceId, attestations: attestations);
  }

  /// The id the server gave the device at enrolment (the `did` claim).
  final String deviceId;

  /// The attestation of each key the device holds. The ambient one is always there.
  final Map<KeyRole, Attestation> attestations;

  /// The attestation of [role], or null when the device has no key of that role.
  Attestation? attestation(KeyRole role) => attestations[role];

  /// This credential with [attestation] for [role] (a renewal's result).
  DeviceCredential withAttestation(KeyRole role, Attestation attestation) =>
      DeviceCredential(
        deviceId: deviceId,
        attestations: {...attestations, role: attestation},
      );

  @override
  DateTime? get expiresAt => attestations[KeyRole.ambient]!.expiresAt;

  @override
  DateTime? get renewableUntil => null;

  @override
  bool get renewable => true;

  @override
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'attestations': {
      for (final entry in attestations.entries) entry.key.name: entry.value.jws,
    },
  };

  static const MapEquality<KeyRole, Attestation> _equality =
      MapEquality<KeyRole, Attestation>();

  @override
  bool operator ==(Object other) =>
      other is DeviceCredential &&
      other.deviceId == deviceId &&
      _equality.equals(other.attestations, attestations);

  @override
  int get hashCode => Object.hash(deviceId, _equality.hash(attestations));

  /// The roles only: neither the device id nor an attestation.
  @override
  String toString() =>
      'DeviceCredential(${(attestations.keys.map((r) => r.name).toList()..sort()).join(', ')})';
}
