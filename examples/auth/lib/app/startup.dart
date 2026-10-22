import 'dart:async';

import 'package:auth/auth_setup.dart';
import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// Runs once, before the app, while splash.dart shows: builds the app's one transport, and reads
/// the stored session. The overrides it returns are what the app's ProviderScope starts with, so
/// the very first navigation already knows who is signed in.
///
/// The transport is built here, once, and goes to the package that sends: `authSetup` gives it to
/// `AuthConfig` (the API calls, which `authTransport` signs with the session) and to the OIDC
/// backend (the token endpoint). `restoreAuth` does no network and is synchronous with a
/// synchronous store; the default `SecureTokenStore` is one keychain read. In a real app the
/// transport is `HttpClientTransport(http.Client())`; here it reaches the in-process demo server.
FutureOr<List<Override>> startup() {
  final transport = apiTransport();
  return restoreAuth(authSetup(transport));
}
