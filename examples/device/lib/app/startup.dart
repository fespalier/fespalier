import 'dart:async';

import 'package:device/device_setup.dart';
import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// Runs once, before the app, while splash.dart shows: builds the app's one transport and restores
/// the session. The overrides it returns are what the app's ProviderScope starts with, so the very
/// first navigation already knows whether this device is enrolled.
///
/// The restore reads the stored attestation, with no network, and asks the backend whether the
/// device key is still the one the attestation is bound to: a swapped or wiped key is a
/// `SignedOut(keyLost)` before the first frame. Nothing here reads or stores a token: there is none.
FutureOr<List<Override>> startup() {
  final transport = apiTransport();
  return restoreAuth(authSetup(transport));
}
