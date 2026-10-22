import 'package:fespalier/startup.dart';
import 'package:fespalier_frb/fespalier_frb.dart' show initRustCore;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:frb_cose_example/src/config.dart';
import 'package:frb_cose_example/src/device_key.dart';
import 'package:frb_cose_example/src/frb_core.dart';
import 'package:frb_cose_example/src/wiring.dart';

/// Runs once, before the app, while splash.dart shows: loads the Rust core (`initRustCore`, which reports it), opens
/// the device key and opens the core with it, pinning the server's key from the build's `--dart-define`s. Nothing is
/// sent here: the core registers the device at its first call, and an unreachable server is an offline app, not a
/// failed start.
///
/// **The web has no core.** The core is a native library, and a web build has none (hook/build.dart builds nothing
/// there), so startup() returns the unavailable core before it touches the bindings: no `RustLib.init`, no request.
/// The pages say so.
///
/// **Where the hardware key is unavailable** a software key is used instead, as in examples/cose, so the example runs
/// on every platform a person may try it on, and `/core` says which key it is (`DeviceKeyKind`, device_key.dart):
///
/// - Linux and Windows have no keystore: flutter-sign-keypair gives them its own software signer, so the key is in
///   memory and `isHardwareBacked()` says false (`software`);
/// - an iOS simulator's keychain opens, but it is not a secure element: the same answer (`software`);
/// - macOS is sandboxed, and an ad-hoc signed build cannot write a keychain item without a development certificate: the
///   first key write throws (OSStatus -34018), and this falls back to a `SoftwareDpopSigner` (`inMemory`);
/// - a phone's keystore that fails lands there too, and `/core` is where a person sees it.
///
/// The web never gets here: it returns the unavailable core above. A software key in memory does not survive a restart,
/// so a restarted app is a new device to the server. A build that must **require** hardware passes
/// `requireHardware: true` to `openDeviceSigner` (device_key.dart) and takes the failure instead (the splash screen
/// shows it).
Future<List<Override>> startup() async {
  if (kIsWeb) return unavailableOverrides();
  final pin = ServerPin.fromEnvironment();
  await initRustCore(loadRustCore);
  final (:signer, :kind) = await openDeviceSigner();
  final jwk = await signer.publicJwk();
  final deviceX = p256Coordinate('x', jwk['x']);
  final deviceY = p256Coordinate('y', jwk['y']);
  final core = await openNotesCore(
    config: pin.configFor(deviceX: deviceX, deviceY: deviceY),
    signer: signer,
  );
  return coreOverrides(
    core: core,
    identity: identityOf(x: deviceX, y: deviceY),
    keyKind: kind,
  );
}
