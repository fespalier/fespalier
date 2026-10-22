import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

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

/// The device key. On a device it is `HardwareKeypairSigner`, the ambient key of flutter-sign-keypair
/// (Secure Enclave, StrongBox or the TEE), made on first use and found again at the next start.
/// A test overrides it with `SoftwareKeypairSigner`, a pure-Dart key.
final deviceSigner = Provider<KeypairSigner>(
  (ref) => HardwareKeypairSigner(keyId: deviceKeyId),
);

/// The public half of the device key, read once by `startup()`: its thumbprint names the account
/// (`crateStackScope`), its `kid` goes into every header.
final deviceIdentity = Provider<Esp256VerifyKey>(
  (ref) => throw UnimplementedError(
    'Override deviceIdentity (startup.dart does, with the key the signer made).',
  ),
);

/// The app's one `HttpTransport`, which every call goes through. `startup()` builds it once
/// (`HttpClientTransport` over `package:http`) and overrides this; a test gives a `FakeTransport`
/// or an `HttpClientTransport` over a `MockClient`.
final coseHttpTransport = Provider<HttpTransport>(
  (ref) => throw UnimplementedError(
    'Override coseHttpTransport (startup.dart does; a test passes a fake).',
  ),
);

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

  final KeypairSigner _signer;
  final Esp256VerifyKey _identity;
  final Future<Object?> Function(CrateStackCall call) _send;
  Future<void>? _inFlight;
  bool _registered = false;

  /// Whether the server has answered this run's registration.
  bool get isRegistered => _registered;

  /// Forgets the registration: the server said it does not know the key (it may have restarted).
  void reset() => _registered = false;

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
///
/// **It must not watch the transport.** Registration sends through the very transport whose
/// `beforeSigned` calls this registrar, so watching `crateStackTransport` here closes a cycle —
/// `coseTransport` -> `deviceRegistrar` -> `crateStackTransport` -> `coseTransport` — and Riverpod
/// refuses with a `CircularDependencyError` before any request is made. The send is therefore
/// resolved lazily, inside the callback, at the moment the plain call is actually sent.
final deviceRegistrar = Provider<DeviceRegistrar>((ref) {
  return DeviceRegistrar(
    signer: ref.watch(deviceSigner),
    identity: ref.watch(deviceIdentity),
    send: (call) => ref.read(crateStackTransport).send(call),
  );
});

/// The transport that seals: `crateStackTransport` is this. It registers the device key before
/// the first signed call.
final coseTransport = Provider<CoseTransport>((ref) {
  return CoseTransport(
    config: ref.watch(coseConfig),
    sealer: CoseSealer(ref.watch(deviceSigner)),
    http: ref.watch(coseHttpTransport),
    // Read lazily: the registrar sends through this very transport, for the plain call.
    beforeSigned: () => ref.read(deviceRegistrar).ensure(),
    onUnauthenticated: () => ref.read(deviceRegistrar).reset(),
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
