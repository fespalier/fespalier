import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/verify.dart';
import 'package:fespalier_sign_keypair/verify.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What the demo server saw of one request: enough for a test to say that nothing but a signature
/// was sent.
class ServedRequest {
  /// A request the server was sent.
  ServedRequest(this.method, this.path, this.headers);

  /// The HTTP method.
  final String method;

  /// The path.
  final String path;

  /// The names of the headers it carried, lower-cased.
  final Set<String> headers;

  /// Whether it was a signed call: it carried an `X-Signature`.
  bool get signed => headers.contains('x-signature');

  /// The attestation it carried, when it did.
  String? attestation;

  /// The code `verifyDeviceSignature` refused it with, when it did.
  String? refusedWith;

  /// The device the verified signature belongs to.
  String? deviceId;

  /// The role of the key that signed it.
  KeyRole? signedWith;

  @override
  String toString() => '$method $path';
}

class _Device {
  _Device(this.id, this.phone, this.keys);

  final String id;
  final String phone;
  final Map<KeyRole, Map<String, String>> keys;
  bool revoked = false;

  String get userId => 'user-${phone.replaceAll(RegExp(r'\D'), '')}';
}

class _Enrolment {
  _Enrolment(this.phone, this.keys, this.challenges);

  final String phone;
  final Map<KeyRole, Map<String, String>> keys;
  final Map<KeyRole, String> challenges;
}

class _Renewal {
  _Renewal(this.deviceId, this.role, this.challenge);

  final String deviceId;
  final KeyRole role;
  final String challenge;
}

/// An in-process API on a `MockClient`, so the example runs and is tested with no network. It is
/// what **your server** does for a device-signed app, in pure Dart:
///
/// - **Enrolment** (unsigned, two legs): `POST /device/enrolments` takes the device's public keys
///   and a phone number, "sends" the one-time code ([demoCode]) and answers a challenge per key;
///   `POST /device/enrolments/{id}/confirm` takes the signatures of those challenges and the code,
///   and answers a device id and an **attestation** per key, signed by the issuer key of this server.
///   The subject is derived from the phone number the code was sent to, never said by the client.
/// - **Renewal** (unsigned, two legs): `POST /device/renewals` and `.../{id}/confirm` swap a
///   signature of a fresh challenge, made with a key the device registered, for a new attestation.
/// - **The API** (`GET /me`, `POST /transfers`, `DELETE /devices/{id}`): every call is checked with
///   `verifyDeviceSignature` (the issuer's signature on the attestation, `cnf.jkt`, the request's
///   signature, its freshness, `mth`, `pth`, `aud`, `qsh`, `bdh`) and an in-memory set of `jti`s, so
///   a request is good once. A call that moves money (`POST /transfers`) and the revocation of a
///   device need the **user-present** key.
///
/// The failures are the codes the client classifies (`webankRefusals`): `attestation_expired` and
/// `device_not_active` (renew and send again), `key_not_bound` (the key is not the one enrolled),
/// `device_revoked` (a 403: the device is dead).
///
/// [latency] makes every answer take that long (zero in tests); [attestationLifetime] is read
/// against `clock`, so a test's fake clock ages what the server issued.
class DemoApi {
  /// A server whose attestations live [attestationLifetime].
  DemoApi({
    this.latency = Duration.zero,
    this.attestationLifetime = const Duration(hours: 24),
    SoftwareKeypairSigner? issuer,
  }) : _issuer =
           issuer ??
           SoftwareKeypairSigner(
             keyId: 'demo-issuer',
             store: InMemorySoftwareKeyStore(),
           );

  /// The API the signatures are for: their `aud`.
  static const String audience = 'https://api.example.com';

  /// The `iss` of what the server issues.
  static const String issuerName = 'https://issuer.example.com';

  /// The one-time code the demo "sends" to every phone number.
  static const String demoCode = '123456';

  /// How the signatures are shaped on the wire: the defaults (`X-Signature`, `X-Attestation`).
  static const DeviceSignatureProfile profile = DeviceSignatureProfile(
    audience: audience,
  );

  /// How long every answer takes.
  final Duration latency;

  /// How long an attestation is good, against `clock`.
  final Duration attestationLifetime;

  final SoftwareKeypairSigner _issuer;
  final Random _random = Random.secure();

  final Map<String, _Device> _devices = {};
  final Map<String, _Enrolment> _enrolments = {};
  final Map<String, _Renewal> _renewals = {};

  /// The `jti`s of the requests it accepted: a signature is good once.
  final Set<String> seenJtis = {};

  /// Every request that reached the server, in order.
  final List<ServedRequest> served = [];

  /// The phone numbers it sent the one-time code to, in order.
  final List<String> smsSent = [];

  /// How many enrolments it confirmed.
  int enrolments = 0;

  /// How many attestations it renewed.
  int renewals = 0;

  /// How many devices were revoked.
  int revocations = 0;

  /// The transfers it accepted: the recipient of each.
  final List<String> transfers = [];

  /// The server as an `http.Client`.
  late final http.Client client = MockClient(_handle);

  /// The server as the `HttpTransport` the app sends through (what `HttpClientTransport(client)`
  /// makes): in your app it is `HttpClientTransport(http.Client())`.
  late final HttpTransport transport = HttpClientTransport(client);

  /// Whether [deviceId] was revoked.
  bool isRevoked(String deviceId) => _devices[deviceId]?.revoked ?? false;

  /// The ids of the devices that enrolled, in order.
  List<String> get devices => _devices.keys.toList();

  /// Forgets that [deviceId] was ever enrolled, as a server whose database was reset.
  void forgetDevice(String deviceId) => _devices.remove(deviceId);

  Future<http.Response> _handle(http.Request request) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final path = request.url.path;
    final record = ServedRequest(request.method, path, {
      for (final name in request.headers.keys) name.toLowerCase(),
    });
    served.add(record);
    final confirm = RegExp(
      r'^/device/(enrolments|renewals)/([^/]+)/confirm$',
    ).firstMatch(path);
    if (request.method == 'POST') {
      if (path == '/device/enrolments') return _beginEnrolment(request);
      if (path == '/device/renewals') return _beginRenewal(request);
      if (confirm != null && confirm.group(1) == 'enrolments') {
        return _confirmEnrolment(confirm.group(2)!, request);
      }
      if (confirm != null) return _confirmRenewal(confirm.group(2)!, request);
      if (path == '/transfers') {
        return _signed(request, record, _transfer);
      }
    }
    if (request.method == 'GET' && path == '/me') {
      return _signed(request, record, _me);
    }
    if (request.method == 'DELETE' && path.startsWith('/devices/')) {
      return _signed(request, record, _revoke);
    }
    return _json({'error': 'not_found'}, 404);
  }

  // ----------------------------------------------------------------------------------- enrolment

  Future<http.Response> _beginEnrolment(http.Request request) async {
    final body = _object(request.body);
    final phone = '${body['phone']}'.replaceAll(' ', '');
    if (!RegExp(r'^\+\d{8,15}$').hasMatch(phone)) {
      return _fieldErrors({
        'phone': 'Enter a phone number like +237 6 55 00 00 00',
      });
    }
    final keys = _publicKeys(body['keys']);
    if (keys == null || !keys.containsKey(KeyRole.ambient)) {
      return _json({'error': 'bad_jwk'}, 400);
    }
    final id = 'enrolment-${_enrolments.length + 1}';
    final challenges = {for (final role in keys.keys) role: _challenge()};
    _enrolments[id] = _Enrolment(phone, keys, challenges);
    // A real server texts the code here; the demo's code is always demoCode.
    smsSent.add(phone);
    return _json({
      'enrolmentId': id,
      'challenges': {
        for (final entry in challenges.entries) entry.key.name: entry.value,
      },
    });
  }

  Future<http.Response> _confirmEnrolment(
    String id,
    http.Request request,
  ) async {
    final body = _object(request.body);
    final enrolment = _enrolments[id];
    if (enrolment == null) return _json({'error': 'unknown_enrolment'}, 403);
    if (body['otp'] != demoCode) {
      return _fieldErrors({'otp': 'That code is not right'});
    }
    final signatures = _object(body['signatures']);
    for (final entry in enrolment.keys.entries) {
      final signature = signatures[entry.key.name];
      if (signature is! String ||
          !_signsChallenge(
            entry.value,
            signature,
            enrolment.challenges[entry.key]!,
          )) {
        return _json({'error': 'invalid_signature'}, 403);
      }
    }
    _enrolments.remove(id);
    final device = _Device(
      'device-${_devices.length + 1}',
      enrolment.phone,
      enrolment.keys,
    );
    _devices[device.id] = device;
    enrolments++;
    return _json({
      'deviceId': device.id,
      'attestations': {
        for (final entry in device.keys.entries)
          entry.key.name: await _issue(device, entry.value),
      },
      'user': {'id': device.userId, 'name': device.phone},
    });
  }

  // ------------------------------------------------------------------------------------ renewal

  Future<http.Response> _beginRenewal(http.Request request) async {
    final body = _object(request.body);
    final device = _devices[body['deviceId']];
    final role = KeyRole.values.asNameMap()[body['role']];
    if (device == null || device.revoked) {
      return _json({'error': 'device_revoked'}, 403);
    }
    if (role == null || !device.keys.containsKey(role)) {
      return _json({'error': 'bad_jwk'}, 400);
    }
    final id = 'renewal-${_renewals.length + 1}';
    final challenge = _challenge();
    _renewals[id] = _Renewal(device.id, role, challenge);
    return _json({'challengeId': id, 'challenge': challenge});
  }

  Future<http.Response> _confirmRenewal(String id, http.Request request) async {
    final renewal = _renewals.remove(id);
    final device = renewal == null ? null : _devices[renewal.deviceId];
    if (renewal == null || device == null || device.revoked) {
      return _json({'error': 'device_revoked'}, 403);
    }
    final signature = _object(request.body)['signature'];
    final jwk = device.keys[renewal.role]!;
    if (signature is! String ||
        !_signsChallenge(jwk, signature, renewal.challenge)) {
      return _json({'error': 'invalid_signature'}, 403);
    }
    renewals++;
    return _json({'attestation': await _issue(device, jwk)});
  }

  // --------------------------------------------------------------------------------- the API

  /// Checks the request the way a server does, and runs [handler] for the device that signed it.
  Future<http.Response> _signed(
    http.Request request,
    ServedRequest record,
    http.Response Function(_Device device, KeyRole role, http.Request request)
    handler,
  ) async {
    record.attestation = request.headers[profile.attestationHeader];
    final VerifiedDeviceRequest verified;
    try {
      verified = verifyDeviceSignature(
        method: request.method,
        uri: request.url,
        headers: request.headers,
        body: request.bodyBytes,
        profile: profile,
        issuerKeys: [await _issuer.publicJwk()],
        seenJtis: seenJtis,
      );
    } on DeviceSignatureInvalid catch (invalid) {
      record.refusedWith = invalid.code;
      return _json({'error': invalid.code}, 401);
    }
    final device = _devices[verified.deviceId];
    if (device == null || device.revoked) {
      record.refusedWith = 'device_not_active';
      return _json({'error': 'device_not_active'}, 401);
    }
    final role = device.keys.entries
        .where((e) => jwkThumbprint(e.value) == verified.thumbprint)
        .map((e) => e.key)
        .firstOrNull;
    if (role == null) {
      record.refusedWith = 'key_not_bound';
      return _json({'error': 'key_not_bound'}, 401);
    }
    record.deviceId = device.id;
    record.signedWith = role;
    return handler(device, role, request);
  }

  http.Response _me(_Device device, KeyRole role, http.Request request) =>
      _json({
        'id': device.userId,
        'name': device.phone,
        'phone': device.phone,
        'deviceId': device.id,
        'signedWith': role.name,
      });

  http.Response _transfer(_Device device, KeyRole role, http.Request request) {
    // A call that moves money needs the key that proves the user is there.
    if (role != KeyRole.userPresent) {
      return _json({'error': 'user_presence_required'}, 403);
    }
    final body = _object(request.body);
    transfers.add('${body['to']}');
    return _json({
      'id': transfers.length,
      'to': body['to'],
      'cents': body['cents'],
    }, 201);
  }

  http.Response _revoke(_Device device, KeyRole role, http.Request request) {
    if (request.url.pathSegments.last != device.id) {
      return _json({'error': 'forbidden'}, 403);
    }
    // A device that holds a user-present key revokes with it: it prompts.
    if (device.keys.containsKey(KeyRole.userPresent) &&
        role != KeyRole.userPresent) {
      return _json({'error': 'user_presence_required'}, 403);
    }
    device.revoked = true;
    revocations++;
    return http.Response('', 204);
  }

  // --------------------------------------------------------------------------------- the issuer

  /// An attestation for [jwk], issued now by this server for [device]: a compact JWS signed with
  /// the issuer key, bound to the key by `cnf.jkt`, and useless without a signature from it.
  Future<String> _issue(_Device device, Map<String, String> jwk) {
    final now = clock.now().millisecondsSinceEpoch ~/ 1000;
    return compactJws(
      const <String, Object?>{'alg': 'ES256', 'typ': 'JWT'},
      <String, Object?>{
        'iss': issuerName,
        'sub': device.userId,
        'did': device.id,
        'iat': now,
        'exp': now + attestationLifetime.inSeconds,
        'cnf': <String, Object?>{'jkt': jwkThumbprint(jwk)},
        'status': 'active',
      },
      _issuer,
    );
  }

  String _challenge() => base64UrlNoPad(
    List<int>.generate(24, (_) => _random.nextInt(256), growable: false),
  );

  /// Whether [signature] is a compact JWS `{alg: ES256}` over `{"challenge": [challenge]}` made
  /// by the key [jwk].
  bool _signsChallenge(
    Map<String, String> jwk,
    String signature,
    String challenge,
  ) {
    final parts = signature.split('.');
    if (parts.length != 3) return false;
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

  // ---------------------------------------------------------------------------------- the wire

  Map<KeyRole, Map<String, String>>? _publicKeys(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final keys = <KeyRole, Map<String, String>>{};
    for (final entry in raw.entries) {
      final role = KeyRole.values.asNameMap()[entry.key];
      final jwk = publicP256Jwk(entry.value);
      if (role == null || jwk == null) return null;
      keys[role] = jwk;
    }
    return keys;
  }

  Map<String, Object?> _object(Object? raw) {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    return decoded is Map<String, Object?> ? decoded : <String, Object?>{};
  }

  http.Response _fieldErrors(Map<String, String> fields) =>
      _json({'errors': fields}, 422);

  http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}
