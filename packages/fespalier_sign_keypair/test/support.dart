// Shared by the tests: a resource server that verifies every send with verifyDeviceSignature, a
// clock a test moves by hand, and a rig that enrols a device on a FakeDeviceAuthServer and sends
// through a real SessionTransport. Nothing here waits for real time.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:fespalier_sign_keypair/verify.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart'
    show addTearDown, expect, isEmpty;

const audience = 'https://api.example.com';
final api = Uri.parse(audience);
const profile = DeviceSignatureProfile(audience: audience);

/// A clock a test moves by hand: `time.run(body)` runs `body` (and everything it awaits) on it.
final class TestTime {
  /// Starts at a fixed instant.
  TestTime([DateTime? start]) : now = start ?? DateTime.utc(2026, 10, 3, 12);

  /// The instant `clock.now()` answers.
  DateTime now;

  /// Moves [now] on.
  void elapse(Duration by) => now = now.add(by);

  /// Runs [body] with `clock.now()` reading [now].
  T run<T>(T Function() body) => withClock(Clock(() => now), body);
}

/// Runs [body] on a clock a test moves by hand, which starts at a fixed instant.
Future<void> clocked(Future<void> Function(TestTime time) body) {
  final time = TestTime();
  return time.run(() => body(time));
}

/// One send the API saw.
final class Seen {
  Seen(this.request, this.body, this.failure, this.verified);

  /// The request as it arrived.
  final TransportRequest request;

  /// Its body bytes.
  final Uint8List body;

  /// Why verifyDeviceSignature refused it, or null.
  final DeviceSignatureInvalid? failure;

  /// What verifyDeviceSignature said of it, when it accepted it.
  final VerifiedDeviceRequest? verified;

  Map<String, String> get lowerHeaders => {
    for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
  };

  String get jti => verified!.jti;
  String? get attestation => lowerHeaders['x-attestation'];
  String? get signature => lowerHeaders['x-signature'];
}

/// A resource server: verifies every send the way a real one does (the attestation, the key
/// binding, the signature, the freshness, the request's method, path, query and body, the single use
/// of the `jti`) and records what it saw. A send that does not verify is answered
/// `401 {"error": <code>}`. [script] answers the next sends instead, in order (the verification
/// is still recorded): a `TransportResponse` or a `TransportFailure` to throw.
final class DeviceApi implements HttpTransport {
  DeviceApi(this.server);

  final FakeDeviceAuthServer server;
  final List<Seen> seen = [];
  final Set<String> jtis = {};
  final List<Object> script = [];

  /// Every send verified?
  List<Seen> get refused => [
    for (final s in seen)
      if (s.failure != null) s,
  ];

  List<String> get verifiedJtis => [
    for (final s in seen)
      if (s.verified != null) s.jti,
  ];

  /// What [path] was sent as.
  List<Seen> to(String path) => [
    for (final s in seen)
      if (s.request.uri.path == path) s,
  ];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final stream = request.bodyStream;
    final Uint8List body;
    if (stream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        builder.add(chunk);
      }
      body = builder.takeBytes();
    } else {
      body = request.body ?? Uint8List(0);
    }
    DeviceSignatureInvalid? failure;
    VerifiedDeviceRequest? verified;
    try {
      verified = verifyDeviceSignature(
        method: request.method,
        uri: request.uri,
        headers: request.headers,
        body: body,
        profile: profile,
        issuerKeys: await server.issuerKeys,
        seenJtis: jtis,
      );
    } on DeviceSignatureInvalid catch (error) {
      failure = error;
    }
    seen.add(Seen(request, body, failure, verified));
    if (script.isNotEmpty) {
      final next = script.removeAt(0);
      if (next is TransportFailure) throw next;
      return next as TransportResponse;
    }
    if (failure != null) return refusal(401, failure.code);
    return fakeResponse(200, body: '{"ok":true}');
  }
}

/// A `{"error": code}` answer.
TransportResponse refusal(int status, String code) =>
    fakeResponse(status, body: jsonEncode({'error': code}));

/// The whole stack: a FakeDeviceAuthServer, the keys (fakes that count prompts), the backend, a
/// container with a store, and the transport a client sends through.
final class Rig {
  Rig._({
    required this.server,
    required this.api,
    required this.ambient,
    required this.userPresent,
    required this.backend,
    required this.store,
    required this.container,
  });

  static Rig create({
    FakeDeviceAuthServer? server,
    FakeKeypairSigner? ambient,
    FakeKeypairSigner? userPresent,
    bool withUserPresent = true,
    MemoryTokenStore? store,
    HttpTransport Function(DeviceApi api)? below,
  }) {
    final fake = server ?? FakeDeviceAuthServer();
    final api = DeviceApi(fake);
    final ambientKey = ambient ?? FakeKeypairSigner(keyId: 'ambient');
    final presenceKey = withUserPresent
        ? (userPresent ??
              FakeKeypairSigner(
                role: KeyRole.userPresent,
                keyId: 'user-present',
                seed: 'fespalier_sign_keypair fake user-present key',
              ))
        : null;
    final backend = DeviceAuthBackend(
      server: fake,
      keys: DeviceKeys(ambient: ambientKey, userPresent: presenceKey),
      profile: profile,
    );
    final memory = store ?? MemoryTokenStore();
    final container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(
          AuthConfig(
            backend: backend,
            transport: below?.call(api) ?? api,
            store: memory,
            apiOrigins: [Uri.parse(audience)],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return Rig._(
      server: fake,
      api: api,
      ambient: ambientKey,
      userPresent: presenceKey,
      backend: backend,
      store: memory,
      container: container,
    );
  }

  final FakeDeviceAuthServer server;
  final DeviceApi api;
  final FakeKeypairSigner ambient;
  final FakeKeypairSigner? userPresent;
  final DeviceAuthBackend backend;
  final MemoryTokenStore store;
  final ProviderContainer container;

  AuthSessionNotifier get notifier => container.read(authSession.notifier);

  SessionState get state => container.read(authSession);

  /// A session transport over the API: what a client sends through.
  HttpTransport get transport => container.read(authTransport);

  DeviceCredential get credential =>
      (notifier.session!.credential as DeviceCredential);

  /// Enrols the device on the server with the right code.
  Future<AuthSession> enrol({String? code}) async {
    final challenge = await backend.beginEnrolment(
      fields: const {'phone': '+237600000000'},
    );
    return notifier.signIn(
      CompleteEnrolment(challenge, proof: code ?? server.otp),
    );
  }

  /// A request to [path] on the API.
  TransportRequest request(
    String path, {
    String method = 'GET',
    Map<String, String> headers = const {},
    List<int>? body,
    Map<String, Object?> attributes = const {},
  }) => TransportRequest(
    method: method,
    uri: Uri.parse('$audience$path'),
    headers: headers,
    body: body == null ? null : Uint8List.fromList(body),
    attributes: attributes,
  );

  Future<TransportResponse> send(
    String path, {
    String method = 'GET',
    List<int>? body,
    Map<String, Object?> attributes = const {},
  }) => transport.send(
    request(path, method: method, body: body, attributes: attributes),
  );

  /// Every send was verified by the API.
  void expectAllVerified() {
    expect(
      api.refused.map((s) => s.failure?.toString()).toList(),
      isEmpty,
      reason: 'the API refused a send',
    );
  }
}

/// A response body as text.
Future<String> text(TransportResponse response) async =>
    utf8.decode(await response.bytes());
