import 'package:cratestack_example/src/config.dart';
import 'package:cratestack_example/src/session.dart';
import 'package:cratestack_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier/startup.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;

/// Runs once, before the app, while splash.dart shows: builds the app's one transport, restores the
/// session and wires the generated client to both.
///
/// **The one transport** (the only place `package:http` is named), outermost first, in the order
/// docs/transport.md gives:
///
/// - `PortalTransport`: a captive portal's `text/html` answer becomes a `TransportPortal`, which
///   `TransportFailures.read` reads as offline;
/// - `WriteGuardTransport`: marks each answer as a write's or a read's, so a retrier leaves a write
///   alone;
/// - `HttpClientTransport(http.Client())`: the network.
///
/// `restoreAuth` puts the session (`SessionTransport`, which signs) on top of it for the API
/// calls, and gives the bare chain to the device ceremonies; `ordersOverrides` hands the session to
/// the generated client. Nothing here reads or stores a token: there is none.
Future<List<Override>> startup() async {
  final network = PortalTransport(
    WriteGuardTransport(HttpClientTransport(http.Client())),
  );
  final config = OrdersConfig.fromEnvironment();
  final auth = await restoreAuth(authSetup(network, config));
  return [...auth, ...ordersOverrides(config)];
}

/// Runs on the app's container, before the router: a session that ends without the user asking (a
/// revoked device, a lost key) wipes what this phone kept for that account ([wipeWhenSessionEnds]).
void ready(ProviderContainer container) => wipeWhenSessionEnds(container);
