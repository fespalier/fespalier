/// How a device-signed request is shaped on the wire (since 0.21.0): the audience the signature
/// is for, the two header names, and how long one signature lives. The defaults are Webank's.
///
/// ```dart
/// const profile = DeviceSignatureProfile(audience: 'https://api.example.com');
/// ```
final class DeviceSignatureProfile {
  /// A profile for the API [audience]. The signature goes in [signatureHeader] and the
  /// attestation in [attestationHeader]; a signature lives for [lifetime], at most five minutes
  /// (`DeviceSigner` refuses a longer one).
  const DeviceSignatureProfile({
    required this.audience,
    this.signatureHeader = 'X-Signature',
    this.attestationHeader = 'X-Attestation',
    this.lifetime = const Duration(minutes: 5),
  });

  /// The longest a signature may live: five minutes, `exp - iat`. A server refuses a longer one.
  static const Duration maxLifetime = Duration(minutes: 5);

  /// What the signature's `aud` claim is: the API it is for. A signature made for one API is
  /// refused by another.
  final String audience;

  /// The header that carries the signature (a compact JWS). `X-Signature`.
  final String signatureHeader;

  /// The header that carries the attestation, unchanged. `X-Attestation`.
  final String attestationHeader;

  /// How long one signature is valid: `exp` is `iat` plus this. Five minutes by default and at
  /// most [maxLifetime].
  final Duration lifetime;

  @override
  bool operator ==(Object other) =>
      other is DeviceSignatureProfile &&
      other.audience == audience &&
      other.signatureHeader == signatureHeader &&
      other.attestationHeader == attestationHeader &&
      other.lifetime == lifetime;

  @override
  int get hashCode =>
      Object.hash(audience, signatureHeader, attestationHeader, lifetime);

  @override
  String toString() => 'DeviceSignatureProfile($audience)';
}
