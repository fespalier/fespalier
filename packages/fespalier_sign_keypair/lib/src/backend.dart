import 'dart:async';
import 'dart:math';

import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'attestation.dart';
import 'credential.dart';
import 'errors.dart';
import 'keys.dart';
import 'profile.dart';
import 'server.dart';
import 'signer.dart';

/// A session made of a device key, not a token (since 0.21.0): enrolling the device is signing
/// in, and the session is "this device's key is enrolled and holds a valid attestation". There is
/// no OIDC provider, no access token, no refresh token and no `Authorization` header: every
/// request carries its own signature (`DeviceSigner`).
///
/// ```dart
/// final backend = DeviceAuthBackend(
///   server: ShopDeviceServer(transport), // your endpoints (DeviceAuthServer)
///   keys: DeviceKeys.device(),
///   profile: const DeviceSignatureProfile(audience: 'https://api.example.com'),
/// );
///
/// // the phone screen
/// final challenge = await backend.beginEnrolment(fields: {'phone': phone});
/// // the one-time code screen
/// await ref.read(authSession.notifier).signIn(CompleteEnrolment(challenge, proof: code));
/// ```
///
/// **Enrolment** has two unsigned legs. [beginEnrolment] makes the device's keys, sends their
/// public JWKs and the app's fields, and returns a challenge per key. `signIn(CompleteEnrolment)`
/// signs each challenge with its key (the user-present one prompts), sends the signatures with the
/// one-time code, and keeps the attestations the server returns.
///
/// **Renewal** replaces refresh: [renew] asks for a challenge, signs it with the key (the ambient
/// one silently), and keeps the new attestation. It runs lazily and once at a time (the core
/// owns that), when the ambient attestation is within [renewAhead] of its expiry, or when a
/// request is refused with `attestation_expired` or `device_not_active`. The server answering that
/// the device is dead (an `AuthRejected` from the [server]) ends the session as
/// `SignOutReason.revoked`.
///
/// A restore signs the user out as `SignOutReason.keyLost` when the ambient key is gone or is not
/// the one the attestation is bound to. Signing out revokes the device on the server, best
/// effort, and then deletes both keys.
final class DeviceAuthBackend extends AuthBackend {
  /// A backend over the app's [server] and the device's [keys], for the API in [profile].
  ///
  /// [policy], [classify], [unsignedPaths], [unsigned] and [random] configure the `DeviceSigner`
  /// (see there). [renewAhead] is how long before the ambient attestation expires the next
  /// request renews it: twelve hours by default, which keeps a daily attestation fresh for a
  /// user who opens the app once a day.
  DeviceAuthBackend({
    required this.server,
    required this.keys,
    required this.profile,
    KeyRolePolicy policy = DeviceSigner.requestedRole,
    DeviceRefusalClassifier classify = webankRefusals,
    Iterable<String> unsignedPaths = const <String>[],
    bool Function(TransportRequest request)? unsigned,
    Random? random,
    this.renewAhead = const Duration(hours: 12),
  }) : signer = DeviceSigner(
         keys: keys,
         profile: profile,
         policy: policy,
         classify: classify,
         unsignedPaths: unsignedPaths,
         unsigned: unsigned,
         random: random,
       );

  /// The app's endpoints.
  final DeviceAuthServer server;

  /// The keys of this device.
  final DeviceKeys keys;

  /// The API the signatures are for.
  final DeviceSignatureProfile profile;

  /// What signs and judges every request.
  final DeviceSigner signer;

  @override
  String get name => 'device';

  @override
  final Duration renewAhead;

  @override
  DeviceSigner get authenticator => signer;

  @override
  DeviceCredential readCredential(Map<String, Object?> json) =>
      DeviceCredential.fromJson(json);

  /// Leg one of an enrolment: makes the device's keys (the ambient one, and the user-present one
  /// where the device has it), sends their public keys and the app's [fields], and returns the
  /// challenges to sign. Show the one-time-code screen next, and finish with
  /// `signIn(CompleteEnrolment(challenge, proof: code))`.
  ///
  /// Throws what the [server] throws (`FieldErrors` for a wrong phone number); the keys it made
  /// stay, and the next enrolment uses them.
  Future<EnrolmentChallenge> beginEnrolment({
    Map<String, Object?> fields = const <String, Object?>{},
  }) async {
    final jwks = <KeyRole, Map<String, String>>{};
    for (final role in keys.roles) {
      jwks[role] = await keys[role]!.publicJwk();
    }
    return server.beginEnrolment(EnrolmentStart(keys: jwks, fields: fields));
  }

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! CompleteEnrolment) {
      throw ArgumentError.value(
        request,
        'request',
        'a DeviceAuthBackend signs in with CompleteEnrolment, after beginEnrolment',
      );
    }
    final signatures = <KeyRole, String>{};
    for (final entry in request.challenge.challenges.entries) {
      signatures[entry.key] = await _signChallenge(entry.key, entry.value);
    }
    final enrolment = await server.confirmEnrolment(
      request.challenge,
      signatures,
      request.proof,
    );
    for (final entry in enrolment.attestations.entries) {
      await _expectBound(entry.key, entry.value);
    }
    if (!enrolment.attestations.containsKey(KeyRole.ambient)) {
      throw StateError(
        'fespalier_sign_keypair: the server enrolled the device without an ambient attestation',
      );
    }
    return AuthSession(
      backend: name,
      credential: DeviceCredential(
        deviceId: enrolment.deviceId,
        attestations: enrolment.attestations,
      ),
      user: enrolment.user,
    );
  }

  /// Renews the attestation of the key [hint] names (a [KeyRole]; the ambient key by default):
  /// asks for a challenge, signs it, keeps the new attestation. The ambient key signs silently;
  /// the user-present key prompts, and a refused prompt is a [UserPresenceRefused] that leaves the
  /// session as it is.
  ///
  /// An `AuthRejected` from the [server] (a 403: the device is dead) ends the session as
  /// `SignOutReason.revoked`. Anything else the server throws means it could not be asked, and the
  /// session stays.
  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) async {
    final credential = session.credential as DeviceCredential;
    final role = hint is KeyRole ? hint : KeyRole.ambient;
    try {
      final challenge = await server.beginRenewal(credential.deviceId, role);
      final signature = await _signChallenge(role, challenge.challenge);
      final attestation = await server.confirmRenewal(challenge, signature);
      await _expectBound(role, attestation);
      return session.copyWith(
        credential: credential.withAttestation(role, attestation),
      );
    } on AuthRejected catch (rejected) {
      throw AuthEnded(
        SignOutReason.revoked,
        error: rejected.error,
        description: rejected.description,
      );
    }
  }

  /// The device key is gone, or is not the one the attestation is bound to: `keyLost`. Only the
  /// ambient key decides: a user-present key that biometrics invalidated is not a lost session
  /// (the ambient key is untouched, and the next user-present call says so).
  @override
  Future<SignOutReason?> check(AuthSession session) async {
    final credential = session.credential;
    if (credential is! DeviceCredential) return SignOutReason.keyLost;
    final ambient = keys.ambient;
    if (!await ambient.exists()) return SignOutReason.keyLost;
    final bound = credential.attestation(KeyRole.ambient)!.jkt;
    return jwkThumbprint(await ambient.publicJwk()) == bound
        ? null
        : SignOutReason.keyLost;
  }

  /// Revokes the device on the [server], signed with the user-present key when the device has
  /// one. Errors are thrown (the core records them and goes on): the keys are deleted by
  /// [discard] whatever happens here.
  @override
  Future<void> signOut(AuthSession session) {
    final credential = session.credential as DeviceCredential;
    final presence =
        keys.userPresent != null &&
        credential.attestation(KeyRole.userPresent) != null;
    return server.revoke(
      credential,
      signer.withPolicy(
        (_) => presence ? KeyRole.userPresent : KeyRole.ambient,
      ),
    );
  }

  /// Deletes both keys. Each is tried even if the other fails to delete; the first failure is
  /// thrown afterwards.
  @override
  Future<void> discard(AuthSession session) async {
    Object? failure;
    StackTrace? failureStack;
    for (final signer in [keys.ambient, ?keys.userPresent]) {
      try {
        await signer.deleteKey();
      } catch (error, stackTrace) {
        failure ??= error;
        failureStack ??= stackTrace;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  /// A compact JWS `{alg: ES256, typ: JWT}` over `{"challenge": …}`, signed with the key of
  /// [role]; the user-present key prompts.
  Future<String> _signChallenge(KeyRole role, String challenge) {
    final key = keys[role];
    if (key == null) {
      throw StateError(
        'fespalier_sign_keypair: the server asked for a ${role.name} signature, but this '
        'device holds no such key',
      );
    }
    return refusingPrompts(
      role,
      () => compactJws(
        const <String, Object?>{'alg': 'ES256', 'typ': 'JWT'},
        <String, Object?>{'challenge': challenge},
        key,
        reason: role == KeyRole.userPresent ? 'Confirm it is you' : null,
      ),
    );
  }

  /// Fails loudly when the server bound [attestation] to another key than this device's key of
  /// [role]: the session would be signed out as `keyLost` at its first restore.
  Future<void> _expectBound(KeyRole role, Attestation attestation) async {
    final key = keys[role];
    if (key == null) {
      throw StateError(
        'fespalier_sign_keypair: the server attested a ${role.name} key this device does not hold',
      );
    }
    if (jwkThumbprint(await key.publicJwk()) != attestation.jkt) {
      throw StateError(
        'fespalier_sign_keypair: the ${role.name} attestation is bound to another key than '
        "this device's (cnf.jkt does not match the key's thumbprint)",
      );
    }
  }
}
