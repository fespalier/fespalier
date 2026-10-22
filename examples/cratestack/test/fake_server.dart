// An in-memory stand-in for server/ (the Rust CrateStack server), as a `FakeTransport`: it answers
// the RPC calls the generated client sends, checks every signed one with `verifyDeviceSignature`, and
// records what it saw. The wire (the CBOR request bodies, the `/rpc/procedure.*` paths, the error
// envelope) is the real server's, which test/e2e_test.dart runs against.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cbor/simple.dart' as cbor;
import 'package:clock/clock.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/verify.dart';
import 'package:fespalier_sign_keypair/verify.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';

/// What the fake saw of one request.
class Served {
  Served(this.request, this.body)
    : op = request.uri.path.replaceFirst('/rpc/procedure.', '');

  final TransportRequest request;
  final Uint8List body;

  /// `listOrders`, `placeOrder`, ...
  final String op;

  /// The decoded `args` of the request.
  Map<String, Object?> get args =>
      ((cbor.cbor.decode(body) as Map)['args'] as Map).cast<String, Object?>();

  Map<String, String> get headers => {
    for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
  };

  /// Whether it carried a signature.
  bool get signed => headers.containsKey('x-signature');

  /// The code `verifyDeviceSignature` or the device checks refused it with.
  String? refusedWith;

  /// The key that signed it, when it was accepted.
  KeyRole? signedWith;

  @override
  String toString() => '${request.method} $op';
}

class _Device {
  _Device(this.id, this.phone, this.keys);
  final String id;
  final String phone;
  final Map<KeyRole, Map<String, String>> keys;
  bool revoked = false;
  String get userId => 'user-${phone.replaceAll(RegExp(r'\D'), '')}';
}

class _Pending {
  _Pending(this.keys, this.challenges, [this.phone = '']);
  final Map<KeyRole, Map<String, String>> keys;
  final Map<KeyRole, String> challenges;
  final String phone;
}

/// The server. [transport] is what the app sends through.
class FakeOrdersServer {
  FakeOrdersServer({
    this.attestationLifetime = const Duration(hours: 24),
    SoftwareKeypairSigner? issuer,
  }) : _issuer =
           issuer ??
           SoftwareKeypairSigner(
             keyId: 'fake-issuer',
             store: InMemorySoftwareKeyStore(),
           ) {
    transport = FakeTransport(_handle);
  }

  static const String audience = 'fespalier-cratestack';
  static const String issuerName = 'https://issuer.cratestack.example';
  static const String otp = '123456';
  static const DeviceSignatureProfile profile = DeviceSignatureProfile(
    audience: audience,
  );
  static final Uri origin = Uri.parse('http://127.0.0.1:8788');

  final Duration attestationLifetime;
  final SoftwareKeypairSigner _issuer;
  final Random _random = Random.secure();

  late final FakeTransport transport;

  /// Every request, in order.
  final List<Served> served = [];

  /// How far ahead of the phone's clock this server's runs: what it checks expiries against.
  Duration skew = Duration.zero;

  /// While true, nothing is reachable: each request fails as `TransportUnsent`.
  bool offline = false;

  /// An op whose answer waits for [release]: a slow server.
  final Map<String, Completer<void>> _held = {};

  final Map<String, _Device> _devices = {};
  final Map<String, _Pending> _enrolments = {};
  final Map<String, ({String device, KeyRole role, String challenge})>
  _renewals = {};
  final Map<String, List<Map<String, Object?>>> _orders = {};
  final Map<String, ({String body, int status, String payload})> _stored = {};
  final Set<String> seenJtis = {};

  int enrolments = 0;
  int renewals = 0;
  int revocations = 0;

  /// How many times an `Idempotency-Key` replayed a stored answer.
  int replays = 0;

  /// The `Authorization` headers any request carried.
  int get authorizationHeaders =>
      served.where((s) => s.headers.containsKey('authorization')).length;

  /// Holds the answer to [op] until [release].
  void hold(String op) => _held[op] = Completer<void>();

  void release(String op) => _held.remove(op)?.complete();

  /// Revokes every device, as an operator would.
  void revokeAll() {
    for (final device in _devices.values) {
      device.revoked = true;
    }
  }

  bool isRevoked(String deviceId) => _devices[deviceId]?.revoked ?? false;

  /// Forgets a device, as a server whose database was reset.
  void forgetDevice(String id) => _devices.remove(id);

  Future<TransportResponse> _handle(
    TransportRequest request,
    Uint8List body,
  ) async {
    final record = Served(request, body);
    served.add(record);
    if (offline) throw TransportUnsent(null, request.uri);
    final hold = _held[record.op];
    if (hold != null) await hold.future;
    return switch (record.op) {
      'beginEnrolment' => _beginEnrolment(record),
      'confirmEnrolment' => await _confirmEnrolment(record),
      'beginRenewal' => _beginRenewal(record),
      'confirmRenewal' => await _confirmRenewal(record),
      _ => await _signed(record),
    };
  }

  // ----------------------------------------------------------------------------------- enrolment

  TransportResponse _beginEnrolment(Served call) {
    final args = call.args;
    final phone = '${args['phone']}'.replaceAll(' ', '');
    if (!RegExp(r'^\+\d{8,15}$').hasMatch(phone)) {
      return _refuse(
        422,
        'invalid_argument',
        "field 'phone' must look like +237 6 55 00 00 00",
      );
    }
    final keys = {
      KeyRole.ambient: publicP256Jwk(args['ambient'])!,
      KeyRole.userPresent: ?publicP256Jwk(args['userPresent']),
    };
    final id = _token(8);
    final challenges = {for (final role in keys.keys) role: _token(24)};
    _enrolments[id] = _Pending(keys, challenges, phone);
    return _ok({
      'enrolmentId': id,
      'ambient': challenges[KeyRole.ambient],
      'userPresent': challenges[KeyRole.userPresent],
    });
  }

  Future<TransportResponse> _confirmEnrolment(Served call) async {
    final args = call.args;
    final pending = _enrolments[args['enrolmentId']];
    if (pending == null) return _refuse(404, 'not_found', 'enrolment');
    if (args['otp'] != otp) {
      return _refuse(
        422,
        'invalid_argument',
        "field 'otp' is not the code that was sent",
      );
    }
    for (final entry in pending.keys.entries) {
      final signature = args[entry.key.name];
      if (signature is! String ||
          !_signsChallenge(
            entry.value,
            signature,
            pending.challenges[entry.key]!,
          )) {
        return _refuse(
          403,
          'permission_denied',
          'a challenge was not signed by the key it was sent for',
        );
      }
    }
    _enrolments.remove(args['enrolmentId']);
    final device = _Device(
      'device-${_devices.length + 1}',
      pending.phone,
      pending.keys,
    );
    _devices[device.id] = device;
    enrolments++;
    return _ok({
      'deviceId': device.id,
      'userId': device.userId,
      'phone': device.phone,
      'ambient': await _issue(device, KeyRole.ambient),
      'userPresent': device.keys.containsKey(KeyRole.userPresent)
          ? await _issue(device, KeyRole.userPresent)
          : null,
    });
  }

  // ------------------------------------------------------------------------------------ renewal

  TransportResponse _beginRenewal(Served call) {
    final args = call.args;
    final device = _devices[args['deviceId']];
    if (device == null || device.revoked) {
      return _refuse(403, 'permission_denied', 'device_revoked');
    }
    final role = KeyRole.values.asNameMap()[args['role']];
    if (role == null || !device.keys.containsKey(role)) {
      return _refuse(
        422,
        'invalid_argument',
        "field 'role' is not a key of this device",
      );
    }
    final id = _token(8);
    final challenge = _token(24);
    _renewals[id] = (device: device.id, role: role, challenge: challenge);
    return _ok({'challengeId': id, 'challenge': challenge});
  }

  Future<TransportResponse> _confirmRenewal(Served call) async {
    final args = call.args;
    final renewal = _renewals.remove(args['challengeId']);
    if (renewal == null) return _refuse(404, 'not_found', 'renewal');
    final device = _devices[renewal.device];
    if (device == null || device.revoked) {
      return _refuse(403, 'permission_denied', 'device_revoked');
    }
    final signature = args['signature'];
    if (signature is! String ||
        !_signsChallenge(
          device.keys[renewal.role]!,
          signature,
          renewal.challenge,
        )) {
      return _refuse(
        403,
        'permission_denied',
        "the challenge was not signed by the device's key",
      );
    }
    renewals++;
    return _ok({'attestation': await _issue(device, renewal.role)});
  }

  // --------------------------------------------------------------------------------- the API

  Future<TransportResponse> _signed(Served call) async {
    final request = call.request;
    final VerifiedDeviceRequest verified;
    try {
      verified = verifyDeviceSignature(
        method: request.method,
        uri: request.uri,
        headers: request.headers,
        body: call.body,
        profile: profile,
        issuerKeys: [await _issuer.publicJwk()],
        seenJtis: seenJtis,
        now: clock.now().add(skew),
      );
    } on DeviceSignatureInvalid catch (invalid) {
      call.refusedWith = invalid.code;
      return _json(401, {
        'error': invalid.code,
        'code': 'unauthenticated',
        'message': invalid.code,
      });
    }
    final device = _devices[verified.deviceId];
    if (device == null) {
      call.refusedWith = 'device_not_active';
      return _json(401, {
        'error': 'device_not_active',
        'code': 'unauthenticated',
        'message': 'device_not_active',
      });
    }
    if (device.revoked) {
      call.refusedWith = 'DEVICE_REVOKED';
      return _json(403, {
        'error': 'DEVICE_REVOKED',
        'code': 'permission_denied',
        'message': 'revoked',
      });
    }
    final role = device.keys.entries
        .where((e) => jwkThumbprint(e.value) == verified.thumbprint)
        .map((e) => e.key)
        .firstOrNull;
    if (role == null) {
      call.refusedWith = 'key_not_bound';
      return _json(401, {
        'error': 'key_not_bound',
        'code': 'unauthenticated',
        'message': 'key_not_bound',
      });
    }
    call.signedWith = role;
    final key = call.headers['idempotency-key'];
    final stored = key == null ? null : _stored['${device.userId}/$key'];
    if (stored != null) {
      replays++;
      return _json(stored.status, jsonDecode(stored.payload));
    }
    final answer = _run(call, device, role);
    if (key != null) {
      _stored['${device.userId}/$key'] = (
        body: '',
        status: answer.status,
        payload: answer.payload,
      );
    }
    return _json(answer.status, jsonDecode(answer.payload));
  }

  ({int status, String payload}) _run(
    Served call,
    _Device device,
    KeyRole role,
  ) {
    final orders = _orders.putIfAbsent(
      device.userId,
      () => [
        {'id': 1, 'item': 'Espresso beans', 'quantity': 2, 'status': 'placed'},
        {'id': 2, 'item': 'Oat milk', 'quantity': 6, 'status': 'paid'},
      ],
    );
    ({int status, String payload}) ok(Object? body) =>
        (status: 200, payload: jsonEncode(body));
    ({int status, String payload}) no(
      int status,
      String code,
      String message,
    ) => (
      status: status,
      payload: jsonEncode({'code': code, 'message': message}),
    );
    final args = call.args;
    switch (call.op) {
      case 'account':
        return ok({
          'userId': device.userId,
          'phone': device.phone,
          'deviceId': device.id,
          'signedWith': role.name,
        });
      case 'listOrders':
        return ok({'orders': orders});
      case 'getOrder':
        final found = orders.where((o) => o['id'] == args['id']).firstOrNull;
        return found == null
            ? no(404, 'not_found', 'order ${args['id']}')
            : ok(found);
      case 'placeOrder':
        final item = '${args['item']}'.trim();
        final quantity = args['quantity'] as int;
        if (item.isEmpty || item.length > 40) {
          return no(
            422,
            'invalid_argument',
            "field 'item' must be 1 to 40 characters",
          );
        }
        if (quantity < 1 || quantity > 99) {
          return no(
            422,
            'invalid_argument',
            "field 'quantity' must be between 1 and 99",
          );
        }
        final order = {
          'id': (orders.last['id']! as int) + 1,
          'item': item,
          'quantity': quantity,
          'status': 'placed',
        };
        orders.add(order);
        return ok(order);
      case 'payOrder':
        if (role != KeyRole.userPresent) {
          return no(403, 'permission_denied', 'user_presence_required');
        }
        final order = orders.where((o) => o['id'] == args['id']).firstOrNull;
        if (order == null) return no(404, 'not_found', 'order ${args['id']}');
        if (order['status'] == 'paid') {
          return no(409, 'conflict', 'order ${args['id']} is already paid');
        }
        order['status'] = 'paid';
        return ok(order);
      case 'revokeDevice':
        if (args['deviceId'] != device.id) {
          return no(
            403,
            'permission_denied',
            'a device revokes itself and no other',
          );
        }
        if (device.keys.containsKey(KeyRole.userPresent) &&
            role != KeyRole.userPresent) {
          return no(403, 'permission_denied', 'user_presence_required');
        }
        device.revoked = true;
        revocations++;
        return ok({'deviceId': device.id});
    }
    return no(404, 'not_found', call.op);
  }

  // --------------------------------------------------------------------------------- the issuer

  Future<String> _issue(_Device device, KeyRole role) {
    final now = clock.now().millisecondsSinceEpoch ~/ 1000;
    return compactJws(
      const <String, Object?>{'alg': 'ES256', 'typ': 'JWT'},
      <String, Object?>{
        'iss': issuerName,
        'sub': device.userId,
        'did': device.id,
        'iat': now,
        'exp': now + attestationLifetime.inSeconds,
        'cnf': <String, Object?>{'jkt': jwkThumbprint(device.keys[role]!)},
        'att': role.name,
      },
      _issuer,
    );
  }

  String _token(int bytes) => base64UrlNoPad(
    List<int>.generate(bytes, (_) => _random.nextInt(256), growable: false),
  );

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

  TransportResponse _ok(Object? body) => _json(200, body);

  TransportResponse _refuse(int status, String code, String message) =>
      _json(status, {'code': code, 'message': message});

  TransportResponse _json(int status, Object? body) => fakeResponse(
    status,
    body: jsonEncode(body),
    headers: const {'content-type': 'application/json'},
  );
}
