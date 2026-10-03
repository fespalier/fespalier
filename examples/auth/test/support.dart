// Shared by the tests: the app booted against the in-process demo server, signed out or in.
import 'dart:convert';

import 'package:auth/api.dart';
import 'package:auth/demo/demo_backend.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// The overrides `startup()` would return, with the demo backend over [server], in memory. With a
/// [store] that already holds a session, the app starts signed in.
List<Override> demoOverrides(DemoServer server, {TokenStore? store}) {
  final config = AuthConfig(
    backend: DemoBackend(apiOrigin, server.client),
    store: store ?? MemoryTokenStore(),
    apiOrigins: [apiOrigin],
  );
  // A synchronous store: restoreAuth answers with the list itself, not a Future.
  final restored = restoreAuth(config) as List<Override>;
  return [...restored, authBaseClient.overrideWithValue(server.client)];
}

/// A store that holds the session of [username] as the demo backend makes it.
Future<MemoryTokenStore> signedInStore(
  DemoServer server,
  String username,
) async {
  final session = await DemoBackend(
    apiOrigin,
    server.client,
  ).signIn(PasswordSignIn(username: username, password: username));
  return MemoryTokenStore(jsonEncode(session.toJson()));
}
