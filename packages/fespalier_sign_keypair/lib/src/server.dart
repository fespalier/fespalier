import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';

import 'attestation.dart';
import 'credential.dart';
import 'signer.dart';

/// What the first leg of an enrolment sends (since 0.21.0): the public key of each role the
/// device holds, and whatever else the app's endpoint wants (the phone number).
final class EnrolmentStart {
  /// A start: the public JWK `{crv, kty, x, y}` of each role in [keys], and the app's own
  /// [fields].
  const EnrolmentStart({
    required this.keys,
    this.fields = const <String, Object?>{},
  });

  /// The public key of each role the device holds. The ambient one is always there.
  final Map<KeyRole, Map<String, String>> keys;

  /// The app's own inputs (`{'phone': '+237...'}`): the backend passes them on and reads none.
  final Map<String, Object?> fields;
}

/// What the server answers to the first leg (since 0.21.0): one single-use challenge per key, and
/// whatever the second leg must send back with them (an enrolment id).
final class EnrolmentChallenge {
  /// A challenge: [challenges] by role, and the server's own [data].
  const EnrolmentChallenge({
    required this.challenges,
    this.data = const <String, Object?>{},
  });

  /// The challenge text to sign, for each key the server accepted.
  final Map<KeyRole, String> challenges;

  /// What the server's reply held that the second leg needs; the backend never reads it.
  final Map<String, Object?> data;
}

/// A challenge for one key (since 0.21.0): what a renewal signs.
final class RoleChallenge {
  /// A challenge: the [challenge] text for the key of [role], and the server's own [data].
  const RoleChallenge({
    required this.role,
    required this.challenge,
    this.data = const <String, Object?>{},
  });

  /// The key it is for.
  final KeyRole role;

  /// The text to sign.
  final String challenge;

  /// What the confirming leg needs from this reply (a challenge id, the device id); the backend
  /// never reads it.
  final Map<String, Object?> data;
}

/// What the second leg of an enrolment answers (since 0.21.0): the device, one attestation per
/// key, and who the server resolved the device to.
final class DeviceEnrolment {
  /// An enrolment: the [deviceId], the [attestations] by role and the [user].
  const DeviceEnrolment({
    required this.deviceId,
    required this.attestations,
    required this.user,
  });

  /// The id the server gave the device.
  final String deviceId;

  /// An attestation for each key the server accepted. The ambient one must be there.
  final Map<KeyRole, Attestation> attestations;

  /// The account the server derived from the verified one-time code (the subject is never
  /// something the client says).
  final AuthUser user;
}

/// Finishes an enrolment (since 0.21.0): `AuthSessionNotifier.signIn(CompleteEnrolment(...))`,
/// after `DeviceAuthBackend.beginEnrolment` and the screen that asks for the one-time code.
final class CompleteEnrolment extends SignInRequest {
  /// The second leg: sign [challenge] with each key, and send the signatures with [proof].
  const CompleteEnrolment(this.challenge, {this.proof});

  /// What `DeviceAuthBackend.beginEnrolment` returned.
  final EnrolmentChallenge challenge;

  /// What the user proved: the one-time code, as the app's server wants it.
  final Object? proof;
}

/// The app's side of the device ceremonies (since 0.21.0): the calls to its own endpoints, with
/// its own payloads. `fespalier_sign_keypair` knows the order of the legs, what is signed and
/// what is kept; it knows no URL.
///
/// Four of the calls are unsigned (the two legs of an enrolment, the two of a renewal): send
/// them through the transport you gave `AuthConfig.transport`, which carries no session, or
/// list their paths in `DeviceAuthBackend.unsignedPaths` when they go through `authTransport`.
/// An answer that means "the server confirms this device is dead" (a 403) is thrown as
/// `AuthRejected`; anything that means "could not ask" (offline, a 5xx) is thrown as it is.
///
/// ```dart
/// final class ShopDeviceServer implements DeviceAuthServer {
///   ShopDeviceServer(this.transport);
///   final HttpTransport transport; // AuthConfig.transport: no session on it
///   // ... one method per leg: build the request, send it, decode the JSON
/// }
/// ```
abstract interface class DeviceAuthServer {
  /// Leg one of an enrolment: sends the public keys and the app's fields; the server resolves
  /// the subject, sends the one-time code, and answers one challenge per key. A wrong input is a
  /// `FieldErrors`.
  Future<EnrolmentChallenge> beginEnrolment(EnrolmentStart start);

  /// Leg two: sends [challengeSignatures] (a compact JWS per role, from the keys) with the
  /// [proof] (the one-time code). The answer holds the device id and an attestation per key. A
  /// wrong code is a `FieldErrors`; a refusal is an `AuthRejected`.
  Future<DeviceEnrolment> confirmEnrolment(
    EnrolmentChallenge challenge,
    Map<KeyRole, String> challengeSignatures,
    Object? proof,
  );

  /// Leg one of a renewal: asks for a challenge for the key of [role] of the device [deviceId].
  /// A 403 is an `AuthRejected`: the device is dead.
  Future<RoleChallenge> beginRenewal(String deviceId, KeyRole role);

  /// Leg two: sends the [signature] of [challenge] (a compact JWS) and receives a new
  /// attestation for the same key. A 403 is an `AuthRejected`: the device is dead.
  Future<Attestation> confirmRenewal(RoleChallenge challenge, String signature);

  /// Tells the server this device is gone, at sign-out: best effort, the local keys are deleted
  /// whatever this does. Sign the request with [signer] (`signer.signFor(credential, request)`):
  /// it signs with the user-present key when the device has one, which prompts. A server that
  /// cannot be reached, or a refused prompt, throws, and the sign-out goes on.
  Future<void> revoke(DeviceCredential credential, DeviceSigner signer);
}
