import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:orders_client/orders_client.dart';

import 'config.dart';
import 'confirm_transport.dart';
import 'device_server.dart';
import 'errors.dart';

/// The server this build talks to. `startup()` overrides it from the `--dart-define`s; a test passes
/// its own.
final ordersConfig = Provider<OrdersConfig>(
  (ref) => throw UnimplementedError(
    'Override ordersConfig (startup.dart does, from --dart-define; a test passes its own).',
  ),
);

/// The keys of this device: `KeypairSigners.device` for each role. An ambient key that never prompts
/// (the Secure Enclave, the AndroidKeyStore, or a browser's non-extractable `CryptoKey`) and, where
/// the platform has a secure element, a user-present key that asks for the biometric or the device
/// credential on every signature. The web has the ambient key only.
///
/// `KeypairFallback.software` lets Windows and Linux (no keystore at all) run the example with a key
/// in memory, which is not hardware-backed and does not survive a restart. A production app that
/// promises device-bound sessions keeps the default, `KeypairFallback.refuse`.
DeviceKeys deviceKeys() => DeviceKeys.device(
  keyId: 'fespalier_cratestack_example',
  fallback: KeypairFallback.software,
);

/// The session: a `DeviceAuthBackend` whose server is the generated client over [network], the plain
/// chain with no session on it (`AuthConfig.transport`).
///
/// The store keeps the device id and the attestations, which mean nothing without a signature from
/// the key: there is no token to keep. A test gives its own [keys] (`FakeKeypairSigner`s) and [store]
/// (`MemoryTokenStore`), and a shorter [renewAhead].
AuthConfig authSetup(
  HttpTransport network,
  OrdersConfig config, {
  DeviceKeys? keys,
  TokenStore store = const SecureTokenStore(),
  Duration renewAhead = const Duration(hours: 12),
}) => AuthConfig(
  transport: network,
  store: store,
  backend: DeviceAuthBackend(
    server: OrdersDeviceServer(network, config.server),
    keys: keys ?? deviceKeys(),
    profile: DeviceSignatureProfile(audience: config.audience),
    renewAhead: renewAhead,
  ),
  // Signed requests go to this origin, and to no other.
  apiOrigins: [config.server],
);

/// The backend, for the screens that enrol (`beginEnrolment`) and ask what the device holds.
final Provider<DeviceAuthBackend> deviceBackend = Provider<DeviceAuthBackend>((
  ref,
) {
  final backend = ref.watch(authConfig).backend;
  if (backend is! DeviceAuthBackend) {
    throw StateError('this app signs in with a DeviceAuthBackend');
  }
  return backend;
});

/// What connects the generated client and `fespalier_cratestack` to this app, once.
///
/// - **The generated client's two seams.** `ordersClientTransportProvider` is the app's session,
///   `authTransport` (a `SessionTransport` over the plain chain), behind [ConfirmTransport]: every
///   generated call carries `X-Attestation` and `X-Signature`, and never `Authorization`.
///   `ordersClientBaseUriProvider` is the server's origin. The adapter provider is left at its
///   default: the HTTP adapter over those two.
/// - **The error reader** that classifies what the client throws, so a `TransportUnsent` reads as
///   offline and a validation answer as a field error.
/// - **Whose data it is** (`crateStackScope`): the user, so the saved copy of a read is wiped with a
///   sign-out and never shown to the next account.
List<Override> ordersOverrides(OrdersConfig config) => [
  ordersConfig.overrideWithValue(config),
  ordersClientTransportProvider.overrideWith(
    (ref) => ConfirmTransport(ref.watch(authTransport)),
  ),
  ordersClientBaseUriProvider.overrideWithValue(config.server),
  crateStackErrors.overrideWithValue(ordersErrors),
  crateStackScope.overrideWith((ref) => ref.watch(authUserId)),
];
