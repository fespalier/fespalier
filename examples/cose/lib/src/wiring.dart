import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:http/http.dart' as http;

import 'cose/cose.dart';
import 'cose_transport.dart';
import 'notes.dart';

/// The name the device key lives under in the secure element.
const String deviceKeyId = 'fespalier_cose';

/// The server this build talks to. `startup()` overrides it from the `--dart-define`s.
final coseConfig = Provider<CoseConfig>(
  (ref) => throw UnimplementedError(
    'Override coseConfig (startup.dart does, from --dart-define; a test passes its own).',
  ),
);

/// The device key. On a device it is `SignKeypairSigner`, the ambient key of flutter-sign-keypair
/// (Secure Enclave, StrongBox or the TEE), made on first use and found again at the next start.
/// A test overrides it with `SoftwareDpopSigner`, a pure-Dart key.
final deviceSigner = Provider<DpopSigner>(
  (ref) => SignKeypairSigner(keyId: deviceKeyId),
);

/// The public half of the device key, read once by `startup()`: its thumbprint names the account
/// (`crateStackScope`), its `kid` goes into every header.
final deviceIdentity = Provider<Esp256VerifyKey>(
  (ref) => throw UnimplementedError(
    'Override deviceIdentity (startup.dart does, with the key the signer made).',
  ),
);

/// The HTTP client every call goes through; a test overrides it with a `MockClient`.
final coseHttpClient = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// The device key's thumbprint as lowercase hex: the account the notes belong to, and the `id`
/// the server knows the device by.
String thumbprintHex(Esp256VerifyKey key) => _hex(key.thumbprint);

/// The `kid` as lowercase hex, to show a person which key this is.
String kidHex(Esp256VerifyKey key) => _hex(key.kid);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Tells the server the device's public key, once per run, before the first signed call.
///
/// Registration is the one plain call: a request signed by a key the server does not know yet
/// is a 401, so the key has to arrive first. It proves nothing about who holds the key (see the
/// README): a signature is only worth what the server lets a registered key do.
final class DeviceRegistrar {
  /// A registrar of [signer]'s key that sends through [send].
  DeviceRegistrar({
    required this._signer,
    required this._identity,
    required this._send,
  });

  final DpopSigner _signer;
  final Esp256VerifyKey _identity;
  final Future<Object?> Function(CrateStackCall call) _send;
  Future<void>? _inFlight;
  bool _registered = false;

  /// Whether the server has answered this run's registration.
  bool get isRegistered => _registered;

  /// Registers the key unless this run already did. A failure is not remembered: the next call
  /// tries again, and two callers that arrive together share one request.
  Future<void> ensure() {
    if (_registered) return Future<void>.value();
    return _inFlight ??= _register().whenComplete(() => _inFlight = null);
  }

  Future<void> _register() async {
    final jwk = await _signer.publicJwk();
    final answer = await _send(
      RpcCall(Ops.registerDevice, {'x': jwk['x'], 'y': jwk['y']}),
    );
    final thumbprint = answer is Map<String, Object?>
        ? answer['thumbprint']
        : null;
    if (thumbprint != thumbprintHex(_identity)) {
      // The server holds another key than ours: never carry on as if it were registered.
      throw const CrateStackOffline('the server registered another key');
    }
    _registered = true;
  }
}

/// Registers the device key.
final deviceRegistrar = Provider<DeviceRegistrar>((ref) {
  final transport = ref.watch(crateStackTransport);
  return DeviceRegistrar(
    signer: ref.watch(deviceSigner),
    identity: ref.watch(deviceIdentity),
    send: transport.send,
  );
});

/// The transport that seals: `crateStackTransport` is this. It registers the device key before
/// the first signed call.
final coseTransport = Provider<CoseTransport>((ref) {
  return CoseTransport(
    config: ref.watch(coseConfig),
    sealer: CoseSealer(ref.watch(deviceSigner)),
    client: ref.watch(coseHttpClient),
    // Read lazily: the registrar sends through this very transport, for the plain call.
    beforeSigned: () => ref.read(deviceRegistrar).ensure(),
  );
});

/// The two seams of fespalier_cratestack, filled: the transport, and the account (the device
/// key's thumbprint). `startup()` returns these; a widget test returns `crateStackTestOverrides`
/// instead and keeps `deviceIdentity` and `deviceSigner` for the page.
List<Override> coseOverrides() => [
  crateStackTransport.overrideWith((ref) => ref.watch(coseTransport)),
  crateStackScope.overrideWith(
    (ref) => thumbprintHex(ref.watch(deviceIdentity)),
  ),
];
