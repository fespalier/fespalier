import 'package:cose_example/src/cose/cose.dart';
import 'package:cose_example/src/cose_transport.dart';
import 'package:cose_example/src/wiring.dart';
import 'package:fespalier/startup.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';

/// Runs once, before the app, while splash.dart shows: opens the device key (made on first use,
/// in the Secure Enclave or the AndroidKeyStore) and pins the server's key from the build's
/// `--dart-define`s. Neither touches the network: the device is registered by the first signed
/// call, and an unreachable server is an offline app, not a failed start.
///
/// The web, Windows and Linux have no `SignKeypairSigner`; a build for them passes a
/// `SoftwareDpopSigner` here, whose key lives in memory and is lost at reload.
Future<List<Override>> startup() async {
  final signer = SignKeypairSigner(keyId: deviceKeyId);
  final identity = await CoseSealer(signer).identity();
  return [
    coseConfig.overrideWithValue(CoseConfig.fromEnvironment()),
    deviceSigner.overrideWithValue(signer),
    deviceIdentity.overrideWithValue(identity),
    ...coseOverrides(),
  ];
}
