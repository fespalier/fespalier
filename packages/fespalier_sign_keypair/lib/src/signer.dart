import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'credential.dart';
import 'errors.dart';
import 'keys.dart';
import 'profile.dart';

/// Which key signs a request (since 0.21.0). A user-present key prompts on every use, so a policy
/// must never choose it for background or queued work: only for a call the user is looking at.
typedef KeyRolePolicy = KeyRole Function(TransportRequest request);

/// A refusal a server answered, as a classifier reads it (since 0.21.0).
final class DeviceRefusal {
  /// A refusal: the [role] of the key the request was signed with, the [statusCode], the
  /// lower-case-named [headers], the response [body] when it was read, and whether this send
  /// [retried] after a renewal or a resend.
  const DeviceRefusal({
    required this.role,
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.retried,
  });

  /// The key the refused request was signed with.
  final KeyRole role;

  /// The HTTP status.
  final int statusCode;

  /// The response headers, with lower-case names.
  final Map<String, String> headers;

  /// The response body as text, when it was read (a 401 or a 403 is); else null.
  final String? body;

  /// Whether this send already followed a renewal or a resend.
  final bool retried;

  /// The `error` member of a JSON object body (`{"error": "attestation_expired"}`), lower-cased;
  /// null for any other body.
  String? get error {
    final text = body;
    if (text == null || text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      final error = decoded is Map<String, Object?> ? decoded['error'] : null;
      return error is String ? error.toLowerCase() : null;
    } on FormatException {
      return null;
    }
  }
}

/// Reads a refusal and says what it means for the session (since 0.21.0).
typedef DeviceRefusalClassifier = AuthVerdict Function(DeviceRefusal refusal);

/// Webank's reading of a refusal, the default of [DeviceSigner]:
///
/// * 401 `attestation_expired` or `device_not_active`: [Renew] the attestation of the key that
///   signed (the hint is its [KeyRole]), then send again, once.
/// * 401 `key_not_bound`, `bad_jwk` or `missing_credential`: the server confirms the key is not
///   the one enrolled, so [SessionEnded] with `SignOutReason.keyLost`.
/// * 403 `DEVICE_REVOKED`: [SessionEnded] with `SignOutReason.revoked`.
/// * Anything else: [Accept]. It is ambiguous, so the session is never wiped and a request never
///   loops on it.
AuthVerdict webankRefusals(DeviceRefusal refusal) {
  final error = refusal.error;
  if (error == null) return const Accept();
  if (refusal.statusCode == 401) {
    return switch (error) {
      'attestation_expired' || 'device_not_active' => Renew(hint: refusal.role),
      'key_not_bound' ||
      'bad_jwk' ||
      'missing_credential' => const SessionEnded(SignOutReason.keyLost),
      _ => const Accept(),
    };
  }
  if (refusal.statusCode == 403 && error == 'device_revoked') {
    return const SessionEnded(SignOutReason.revoked);
  }
  return const Accept();
}

/// Signs every request with the device key and reads the refusals (since 0.21.0): the
/// `RequestAuthenticator` of `DeviceAuthBackend`. A request leaves with two headers and **no
/// `Authorization`**:
///
/// * `X-Attestation`: the attestation of the chosen key, unchanged;
/// * `X-Signature`: a compact JWS, header `{"alg":"ES256","jwk":{crv,kty,x,y}}`, claims `iat`,
///   `exp` (`iat` plus the profile's lifetime, at most five minutes), `jti` (fresh on every send,
///   retries and replays included), `mth` (the method, upper-case), `pth` (`uri.path`), `qsh` (the
///   lower-case hex SHA-256 of the raw query, left out when there is none), `bdh` (the same
///   of the exact body bytes, left out when empty) and `aud`.
///
/// The body is hashed as it is on the wire: JSON, CBOR and a finalized multipart alike. A body
/// that is a stream cannot be hashed before it is sent, so a request with one is refused with an
/// `ArgumentError` (a request with no body, a stream of known length 0, or a method that carries
/// none is fine).
///
/// Which key signs is the [policy]'s call: by default the ambient key, or the role in the request's
/// [roleAttribute] (a request made with `Options(extra: {DeviceSigner.roleAttribute:
/// KeyRole.userPresent})` under Dio). A user-present signature prompts; a refused prompt is a
/// [UserPresenceRefused] that fails that one request and leaves the session alone.
final class DeviceSigner implements RequestAuthenticator {
  /// A signer over the device's [keys] for the API in [profile].
  ///
  /// [classify] reads refusals (Webank's rules by default). The calls in [unsignedPaths] (exact
  /// `uri.path` matches), or for which [unsigned] answers true, carry no headers at all: the
  /// enrolment and renewal legs, when they go through the session's transport. [random] makes the
  /// `jti`s; it is `Random.secure()` unless a test passes one. Throws an `ArgumentError` when the
  /// profile's lifetime is not positive or is longer than five minutes.
  DeviceSigner({
    required this.keys,
    required this.profile,
    this.policy = requestedRole,
    this.classify = webankRefusals,
    Iterable<String> unsignedPaths = const <String>[],
    this.unsigned,
    Random? random,
  }) : unsignedPaths = Set<String>.unmodifiable(unsignedPaths),
       _random = random ?? Random.secure() {
    final lifetime = profile.lifetime;
    if (lifetime <= Duration.zero ||
        lifetime > DeviceSignatureProfile.maxLifetime) {
      throw ArgumentError.value(
        lifetime,
        'profile.lifetime',
        'a signature lives for more than zero and at most five minutes',
      );
    }
  }

  /// This signer with another [policy], sharing everything else (keys, profile, classifier,
  /// unsigned calls and the `jti` source).
  DeviceSigner withPolicy(KeyRolePolicy policy) => DeviceSigner(
    keys: keys,
    profile: profile,
    policy: policy,
    classify: classify,
    unsignedPaths: unsignedPaths,
    unsigned: unsigned,
    random: _random,
  );

  /// The request attribute that names the key that signs it: a [KeyRole]. Under Dio it is
  /// `Options(extra: {DeviceSigner.roleAttribute: KeyRole.userPresent})`.
  static const String roleAttribute = 'fespalier.device.role';

  /// The request attribute that captions the user-present prompt: a `String`.
  static const String reasonAttribute = 'fespalier.device.reason';

  /// The default [policy]: the request's [roleAttribute], the ambient key when it has none.
  static KeyRole requestedRole(TransportRequest request) {
    final role = request.attributes[roleAttribute];
    return role is KeyRole ? role : KeyRole.ambient;
  }

  /// The device's keys.
  final DeviceKeys keys;

  /// The API the signatures are for, and the two header names.
  final DeviceSignatureProfile profile;

  /// Which key signs a request.
  final KeyRolePolicy policy;

  /// How a refusal is read.
  final DeviceRefusalClassifier classify;

  /// The `uri.path`s whose calls are sent unsigned.
  final Set<String> unsignedPaths;

  /// Whether a call is sent unsigned, besides [unsignedPaths]; null: none is.
  final bool Function(TransportRequest request)? unsigned;

  final Random _random;

  bool _isUnsigned(TransportRequest request) =>
      unsignedPaths.contains(request.uri.path) ||
      (unsigned?.call(request) ?? false);

  @override
  Future<Map<String, String>> headers(
    AuthSession session,
    TransportRequest request,
  ) async {
    if (_isUnsigned(request)) return const <String, String>{};
    return signFor(_credential(session), request);
  }

  /// The two headers for one send of [request], signed with the key of [role] (the [policy]'s
  /// choice when null) and carrying that role's attestation from [credential]. A fresh `jti`
  /// each call.
  ///
  /// `DeviceAuthServer.revoke` uses it to sign its own call. Throws a `StateError` when the
  /// device has no key, or [credential] no attestation, for the role; an `ArgumentError` for a
  /// stream body; a [UserPresenceRefused] when a user-present prompt is refused.
  Future<Map<String, String>> signFor(
    DeviceCredential credential,
    TransportRequest request, {
    KeyRole? role,
  }) async {
    final chosen = role ?? policy(request);
    final attestation = credential.attestation(chosen);
    final signer = keys[chosen];
    if (signer == null || attestation == null) {
      throw StateError(
        'fespalier_sign_keypair: this request is to be signed with the ${chosen.name} key, '
        'but this device has ${signer == null ? 'no such key' : 'no attestation for it'}. '
        'A user-present call needs a device that enrolled with a user-present key '
        '(not the web, and not a device without a screen lock)',
      );
    }
    final body = _body(request);
    final jwk = await signer.publicJwk();
    final now = clock.now().millisecondsSinceEpoch ~/ 1000;
    final query = request.uri.query;
    final claims = <String, Object?>{
      'iat': now,
      'exp': now + profile.lifetime.inSeconds,
      'jti': _jti(),
      'mth': request.method.toUpperCase(),
      'pth': request.uri.path.isEmpty ? '/' : request.uri.path,
      if (query.isNotEmpty) 'qsh': _hex(utf8.encode(query)),
      if (body.isNotEmpty) 'bdh': _hex(body),
      'aud': profile.audience,
    };
    final reason = request.attributes[reasonAttribute];
    final signature = await refusingPrompts(
      chosen,
      () => compactJws(
        <String, Object?>{
          'alg': 'ES256',
          'jwk': <String, String>{
            'crv': jwk['crv']!,
            'kty': jwk['kty']!,
            'x': jwk['x']!,
            'y': jwk['y']!,
          },
        },
        claims,
        signer,
        reason: reason is String ? reason : null,
      ),
    );
    return <String, String>{
      profile.attestationHeader: attestation.jws,
      profile.signatureHeader: signature,
    };
  }

  @override
  AuthVerdict judge(
    AuthSession session,
    TransportRequest request, {
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  }) {
    if (_isUnsigned(request)) return const Accept();
    return classify(
      DeviceRefusal(
        role: policy(request),
        statusCode: statusCode,
        headers: headers,
        body: body,
        retried: retried,
      ),
    );
  }

  DeviceCredential _credential(AuthSession session) {
    final credential = session.credential;
    if (credential is! DeviceCredential) {
      throw StateError(
        'fespalier_sign_keypair: the session holds a ${credential.runtimeType}, not a '
        'DeviceCredential: a DeviceSigner belongs to a DeviceAuthBackend',
      );
    }
    return credential;
  }

  /// The exact bytes of the body, empty when there is none. A stream that cannot be hashed
  /// before it is sent is an `ArgumentError`.
  Uint8List _body(TransportRequest request) {
    if (request.bodyStream != null) {
      const bodiless = {'GET', 'HEAD', 'OPTIONS', 'TRACE'};
      if (request.contentLength == 0 ||
          bodiless.contains(request.method.toUpperCase())) {
        return Uint8List(0);
      }
      throw ArgumentError.value(
        request.bodyStream,
        'request.bodyStream',
        'a streamed body cannot be signed: its bytes are not known before they are sent, and the '
            'signature covers them. Send the body as bytes (TransportRequest.body; under Dio, '
            'JSON, a form, FormData or a List<int> as data) instead of a Stream',
      );
    }
    return request.body ?? Uint8List(0);
  }

  String _jti() => base64UrlNoPad(
    List<int>.generate(16, (_) => _random.nextInt(256), growable: false),
  );

  static String _hex(List<int> bytes) => sha256.convert(bytes).toString();
}
