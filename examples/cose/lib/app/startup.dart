import 'package:cose_example/src/cose/cose.dart';
import 'package:cose_example/src/cose_transport.dart';
import 'package:cose_example/src/wiring.dart';
import 'package:fespalier/startup.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:http/http.dart' as http;

/// Runs once, before the app, while splash.dart shows: builds the app's one transport (the only
/// place `package:http` is named: `HttpClientTransport` over its client, which every call is
/// sent through), opens the device key (made on first use,
/// in the Secure Enclave or the AndroidKeyStore) and pins the server's key from the build's
/// `--dart-define`s. Neither touches the network: the device is registered by the first signed
/// call, and an unreachable server is an offline app, not a failed start.
///
/// **Where the hardware key is unavailable** the software key is used instead, so the example runs
/// on every platform a person may try it on:
///
/// - the web, Windows and Linux have no keystore at all;
/// - macOS is sandboxed, and a sandboxed app cannot write a keychain item without a
///   `keychain-access-groups` entitlement — which in turn needs a real development certificate, so
///   an ad-hoc signed build (`CODE_SIGN_IDENTITY = "-"`, what `flutter create` makes) cannot have
///   one. It fails with OSStatus -34018 at the first key write;
/// - an iOS simulator's keychain is not a secure element.
///
/// The fallback is honest about what it loses: a software key is not hardware-backed and does not
/// survive a restart. `isHardwareBacked()` on the signer says which kind of key it is, but the page
/// does not show it: the page shows the key's `kid`. A build that must *require* hardware passes
/// `requireHardware: true` and takes the failure instead.
Future<List<Override>> startup() async {
  Future<KeypairSigner> openSigner() async {
    try {
      // `requireHardware: false`: use the keystore when there is one, else a software key.
      final hardware = HardwareKeypairSigner(keyId: deviceKeyId);
      await hardware.publicJwk();
      return hardware;
    } on Object {
      // No keystore (the web, Windows, Linux), a sandbox that refuses the keychain (macOS without
      // a signing certificate), or a simulator keychain: fall back rather than fail to start.
      return SoftwareKeypairSigner(keyId: deviceKeyId);
    }
  }

  final signer = await openSigner();
  final identity = await CoseSealer(signer).identity();
  return [
    coseConfig.overrideWithValue(CoseConfig.fromEnvironment()),
    coseHttpTransport.overrideWithValue(HttpClientTransport(http.Client())),
    deviceSigner.overrideWithValue(signer),
    deviceIdentity.overrideWithValue(identity),
    ...coseOverrides(),
  ];
}
