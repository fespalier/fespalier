import 'package:device/demo/demo_api.dart';
import 'package:device/device_server.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'api.dart';

/// The API the app talks to, in process: the demo server. In your app it is your server.
final DemoApi demoApi = DemoApi(latency: const Duration(milliseconds: 250));

/// The one transport the app sends through: `startup()` builds it once and hands it to [authSetup],
/// which gives it to `AuthConfig` (the enrolment and renewal legs, and the revocation) and, wrapped
/// in a `SessionTransport` that signs, to `authTransport` (the API calls).
///
/// In your app it is `HttpClientTransport(http.Client())` and nothing else. Here the API is the
/// demo server, in process.
HttpTransport apiTransport() => HttpClientTransport(demoApi.client);

/// The keys of this device: `KeypairSigners.device` for each role. An ambient key that never
/// prompts (the Secure Enclave, the AndroidKeyStore, or a browser's non-extractable `CryptoKey`),
/// and, where the platform has a secure element, a user-present key that asks for the biometric or
/// the device credential on every signature. The web has the ambient key only.
///
/// `KeypairFallback.software` lets Windows and Linux (no keystore at all) run the example with a
/// key in memory, which is not hardware-backed and does not survive a restart. A production app that
/// promises device-bound sessions keeps the default, `KeypairFallback.refuse`.
DeviceKeys deviceKeys() => DeviceKeys.device(
  keyId: 'fespalier_device_example',
  fallback: KeypairFallback.software,
);

/// The app's [AuthConfig] over [transport]: a `DeviceAuthBackend` over the demo server. A test gives
/// its own [keys] (`FakeKeypairSigner`s) and [store] (`MemoryTokenStore`).
///
/// The session is "this device's key is enrolled and holds a valid attestation": the store keeps
/// the device id and the attestations, which mean nothing without a signature from the key. There
/// is no token to keep.
AuthConfig authSetup(
  HttpTransport transport, {
  DeviceKeys? keys,
  TokenStore store = const SecureTokenStore(),
}) => AuthConfig(
  transport: transport,
  store: store,
  backend: DeviceAuthBackend(
    server: ExampleDeviceServer(transport),
    keys: keys ?? deviceKeys(),
    profile: DemoApi.profile,
  ),
  // Signed requests go to this origin, and to no other.
  apiOrigins: [apiOrigin],
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
