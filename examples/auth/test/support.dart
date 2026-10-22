// Shared by the tests: the app booted against the in-process demo server, signed out or in.
import 'dart:convert';

import 'package:auth/api.dart';
import 'package:auth/demo/demo_backend.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// The overrides `startup()` would return, with the demo backend over [server], in memory. With a
/// [store] that already holds a session, the app starts signed in.
List<Override> demoOverrides(DemoServer server, {TokenStore? store}) {
  final config = AuthConfig(
    backend: DemoBackend(apiOrigin, server.transport),
    transport: server.transport,
    store: store ?? MemoryTokenStore(),
    apiOrigins: [apiOrigin],
  );
  // A synchronous store: restoreAuth answers with the list itself, not a Future.
  return restoreAuth(config) as List<Override>;
}

/// A store that holds the session of [username] as the demo backend makes it.
Future<MemoryTokenStore> signedInStore(
  DemoServer server,
  String username,
) async {
  final session = await DemoBackend(
    apiOrigin,
    server.transport,
  ).signIn(PasswordSignIn(username: username, password: username));
  return MemoryTokenStore(jsonEncode(session.toJson()));
}

/// What an API call answered: its status and its body.
typedef Answer = ({int status, String body});

/// `GET`s [path] on the API through [transport] (a test's `container.read(authTransport)`).
Future<Answer> get(HttpTransport transport, String path) async {
  final response = await transport.send(
    TransportRequest(method: 'GET', uri: api(path)),
  );
  return (
    status: response.statusCode,
    body: utf8.decode(await response.bytes()),
  );
}
