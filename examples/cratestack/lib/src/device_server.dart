import 'dart:async';

import 'package:fespalier/fespalier.dart' show FieldErrors;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:orders_client/orders_client.dart';

import 'errors.dart';

/// The server's own endpoints for the device ceremonies, called through the **generated client**.
///
/// `fespalier_sign_keypair` knows the order of the legs, what is signed and what is kept; it knows no
/// URL and no payload, so this class is the only place that does: the four public procedures of
/// `server/schema.cstack` (`beginEnrolment`, `confirmEnrolment`, `beginRenewal`, `confirmRenewal`) and
/// the signed `revokeDevice`.
///
/// It is built over [AuthConfig.transport]: the plain chain with **no session on it**, so the four
/// legs go out unsigned, by construction (the server lists them by name too). The generated
/// `ordersClientTransportProvider` is the other client, over `authTransport`; this one is made from
/// the same generated classes the provider builds, with the plain chain in their place.
///
/// - A `422` on the phone or the code is the [FieldErrors] a form shows under its field.
/// - A `403` on a renewal is the server confirming that this device is dead: [AuthRejected], and the
///   session ends as revoked.
/// - Anything else (offline, a `5xx`, an unknown enrolment) is thrown as it is: "could not ask", and
///   the session stays.
final class OrdersDeviceServer implements DeviceAuthServer {
  /// The device endpoints of the server at [server], reached through [transport] (no session).
  OrdersDeviceServer(this.transport, Uri server)
    : _server = server,
      _procedures = _clientOver(transport, server);

  /// What the legs go through: `AuthConfig.transport`.
  final HttpTransport transport;

  final Uri _server;
  final ProceduresApi _procedures;

  static ProceduresApi _clientOver(HttpTransport transport, Uri server) =>
      OrdersClientCratestackClient(
        CratestackRpcHttpAdapter(
          CratestackFespalierTransport(transport),
          baseUri: server,
        ),
      ).procedures;

  @override
  Future<EnrolmentChallenge> beginEnrolment(EnrolmentStart start) async {
    final answer = await _leg(
      () => _procedures.beginEnrolment(
        BeginEnrolmentProcedureArgs(
          args: BeginEnrolmentArgs(
            phone: '${start.fields['phone'] ?? ''}',
            ambient: _jwk(start.keys[KeyRole.ambient]!),
            userPresent: switch (start.keys[KeyRole.userPresent]) {
              final jwk? => _jwk(jwk),
              null => null,
            },
          ),
        ),
      ),
    );
    return EnrolmentChallenge(
      challenges: {
        KeyRole.ambient: answer.ambient,
        KeyRole.userPresent: ?answer.userPresent,
      },
      data: {'enrolmentId': answer.enrolmentId},
    );
  }

  @override
  Future<DeviceEnrolment> confirmEnrolment(
    EnrolmentChallenge challenge,
    Map<KeyRole, String> challengeSignatures,
    Object? proof,
  ) async {
    final answer = await _leg(
      () => _procedures.confirmEnrolment(
        ConfirmEnrolmentProcedureArgs(
          args: ConfirmEnrolmentArgs(
            enrolmentId: '${challenge.data['enrolmentId']}',
            otp: '${proof ?? ''}',
            ambient: challengeSignatures[KeyRole.ambient]!,
            userPresent: challengeSignatures[KeyRole.userPresent],
          ),
        ),
      ),
    );
    return DeviceEnrolment(
      deviceId: answer.deviceId,
      attestations: {
        KeyRole.ambient: Attestation.parse(answer.ambient),
        if (answer.userPresent case final jws?)
          KeyRole.userPresent: Attestation.parse(jws),
      },
      user: AuthUser(id: answer.userId, name: answer.phone),
    );
  }

  @override
  Future<RoleChallenge> beginRenewal(String deviceId, KeyRole role) async {
    final answer = await _leg(
      () => _procedures.beginRenewal(
        BeginRenewalProcedureArgs(
          args: BeginRenewalArgs(deviceId: deviceId, role: role.name),
        ),
      ),
      deadIs403: true,
    );
    return RoleChallenge(
      role: role,
      challenge: answer.challenge,
      data: {'challengeId': answer.challengeId},
    );
  }

  @override
  Future<Attestation> confirmRenewal(
    RoleChallenge challenge,
    String signature,
  ) async {
    final answer = await _leg(
      () => _procedures.confirmRenewal(
        ConfirmRenewalProcedureArgs(
          args: ConfirmRenewalArgs(
            challengeId: '${challenge.data['challengeId']}',
            signature: signature,
          ),
        ),
      ),
      deadIs403: true,
    );
    return Attestation.parse(answer.attestation);
  }

  /// `revokeDevice`, **signed by hand**: this call does not go through `authTransport` (the session
  /// is ending), so a transport that signs it with [signer] stands in its place. `signer` is
  /// `DeviceAuthBackend.signOut`'s: it asks for the user-present key when the device has one, which
  /// prompts. A refused prompt or an unreachable server throws, and the sign-out goes on.
  @override
  Future<void> revoke(DeviceCredential credential, DeviceSigner signer) async {
    final signed = _clientOver(
      _SignedBy(transport, credential, signer),
      _server,
    );
    await _leg(
      () => signed.revokeDevice(
        RevokeDeviceArgs(args: RevokeArgs(deviceId: credential.deviceId)),
      ),
    );
  }

  /// One call of a ceremony, mapped. It runs in a zone with **no abort trigger of the caller's**: the
  /// renewal is shared by every request that waits for it, and one page leaving (`ref.cancellable`
  /// puts its trigger in the zone of the load it started) might abort it for the others. That is a
  /// **suspected** `fespalier_auth` issue, read in the source and not yet reproduced or confirmed; this
  /// guards against it until it is.
  Future<T> _leg<T>(Future<T> Function() call, {bool deadIs403 = false}) async {
    final neverAborted = Completer<void>().future;
    try {
      return await TransportZone.run(neverAborted, call);
    } on CratestackRpcException catch (error) {
      if (deadIs403 && error.status == 403) {
        // A device this server does not know, or revoked: the session is over.
        throw const AuthRejected();
      }
      final fields = ordersErrors.fieldErrorsOf(error);
      if (fields != null) throw fields;
      rethrow;
    }
  }

  static Jwk _jwk(Map<String, String> jwk) =>
      Jwk(kty: jwk['kty']!, crv: jwk['crv']!, x: jwk['x']!, y: jwk['y']!);
}

/// A transport that signs every request with [signer] for [credential] before it sends it on.
final class _SignedBy implements HttpTransport {
  const _SignedBy(this.inner, this.credential, this.signer);

  final HttpTransport inner;
  final DeviceCredential credential;
  final DeviceSigner signer;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final signature = await signer.signFor(credential, request);
    return inner.send(
      request.copyWith(headers: {...request.headers, ...signature}),
    );
  }
}
