import 'dart:async';

import 'package:auth/auth_setup.dart';
import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// Runs once, before the app, while splash.dart shows: reads the stored session. The overrides it
/// returns are what the app's ProviderScope starts with, so the very first navigation already
/// knows who is signed in.
///
/// `restoreAuth` does no network and is synchronous with a synchronous store; the default
/// `SecureTokenStore` is one keychain read. The demo's API is in process, so `authBaseClient` is
/// overridden with it; a real app leaves that line out.
FutureOr<List<Override>> startup() {
  List<Override> withApi(List<Override> restored) => [
    ...restored,
    authBaseClient.overrideWithValue(apiClient()),
  ];
  final restored = restoreAuth(authSetup());
  return restored is Future<List<Override>>
      ? restored.then(withApi)
      : withApi(restored);
}
