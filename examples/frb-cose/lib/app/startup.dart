import 'package:fespalier/startup.dart';
import 'package:fespalier_frb/fespalier_frb.dart' show initRustCore;
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:frb_cose_example/src/config.dart';
import 'package:frb_cose_example/src/frb_core.dart';
import 'package:frb_cose_example/src/wiring.dart';

/// The name the device key lives under in the secure element.
const String deviceKeyId = 'frb_cose';

/// Runs once, before the app, while splash.dart shows: loads the Rust core (`initRustCore`, which reports it), opens
/// the device key and opens the core with it, pinning the server's key from the build's `--dart-define`s. Nothing is
/// sent here: the core registers the device at its first call, and an unreachable server is an offline app, not a
/// failed start.
///
/// **The web has no core.** The core is a native library, and a web build has none (hook/build.dart builds nothing
/// there), so startup() returns the unavailable core before it touches the bindings: no `RustLib.init`, no request.
/// The pages say so.
///
/// **Where the hardware key is unavailable** the software key is used instead, as in examples/cose: the web's
/// keystore, a macOS sandbox without a signing certificate and an iOS simulator's keychain. The software key is not
/// hardware-backed and does not survive a restart (README).
Future<List<Override>> startup() async {
  if (kIsWeb) return unavailableOverrides();
  final pin = ServerPin.fromEnvironment();
  await initRustCore(loadRustCore);
  final signer = await _openSigner();
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
  );
}

Future<DpopSigner> _openSigner() async {
  try {
    // The keystore when there is one.
    final hardware = SignKeypairSigner(keyId: deviceKeyId);
    await hardware.publicJwk();
    return hardware;
  } on Object {
    return SoftwareDpopSigner(keyId: deviceKeyId);
  }
}
