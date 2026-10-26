import 'package:auth/api.dart';
import 'package:auth/app.config.g.dart';
import 'package:auth/demo/demo_backend.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// Sign in with a Keycloak instead of the demo API: `fsp dev --profile keycloak`
/// (`config/app.keycloak.yaml`, the realm of `keycloak/realm-fespalier.json`; on an Android emulator,
/// `adb reverse tcp:8080 tcp:8080`: see the README). Empty in `config/app.yaml`: the demo API's own
/// sign-in.
const String oidcIssuer = AppConfig.oidcIssuer;

/// The Keycloak client: `fespalier-auth-example`.
const String oidcClientId = AppConfig.oidcClientId;

/// Where Keycloak sends the browser back to: registered with the client.
const String oidcRedirect = AppConfig.oidcRedirect;

/// `demo` (`fsp dev --profile demo-dpop`) signs in with OpenID Connect against the demo server's own
/// provider (shaped like Keycloak, in process): no Keycloak, no browser, no network.
const String demoIssuer = 'demo';

/// Binds the tokens to a device key (DPoP, RFC 9449): `fsp dev --profile demo-dpop` against the demo
/// server's provider, `fsp dev --profile keycloak-dpop` against Keycloak, with the client
/// `fespalier-auth-example-dpop`, which requires DPoP-bound tokens. Needs an `oidc.issuer`.
const bool useDpop = AppConfig.dpop;

/// Whether the app signs in with OpenID Connect.
bool get usesOidc => oidcIssuer.isNotEmpty;

/// Whether that provider is the demo server's own.
bool get usesDemoOidc => oidcIssuer == demoIssuer;

/// The API the app talks to, in process: the demo server. With a real Keycloak it takes any token,
/// because the tokens are Keycloak's, which it cannot ask; with its own provider it checks them,
/// and the DPoP proofs when `dpop` is on.
final DemoServer demoServer = DemoServer(
  latency: const Duration(milliseconds: 250),
  trustAnyToken: usesOidc && !usesDemoOidc,
  requireDpop: useDpop && usesDemoOidc,
);

/// A test swaps in its own [AuthConfig] (and, with [debugApiTransport], its own API).
@visibleForTesting
AuthConfig Function(HttpTransport transport)? debugAuthSetup;

/// A test swaps in the transport the app sends through.
@visibleForTesting
HttpTransport Function()? debugApiTransport;

/// The one transport the app sends through: `startup()` builds it once and hands it to
/// [authSetup], which gives it to `AuthConfig` (the API calls, through `authTransport`) and to
/// `OidcBackend` (the token endpoint).
///
/// In your app it is `HttpClientTransport(http.Client())` and nothing else. Here the API is the
/// demo server, in process; with a real Keycloak (`oidc.issuer`) Keycloak is on the network and the
/// API still the demo, so the transport sends each origin where it lives.
HttpTransport apiTransport() {
  final debug = debugApiTransport;
  if (debug != null) return debug();
  final demo = HttpClientTransport(demoServer.client);
  if (!usesOidc || usesDemoOidc) return demo;
  return _ByOrigin(
    routes: {apiOrigin.origin: demo},
    otherwise: HttpClientTransport(http.Client()),
  );
}

/// Sends a request to the transport of its origin, and any other to [otherwise]: a transport is
/// a function of a request, so routing is a decorator like any other.
final class _ByOrigin implements HttpTransport {
  const _ByOrigin({required this.routes, required this.otherwise});

  final Map<String, HttpTransport> routes;
  final HttpTransport otherwise;

  @override
  Future<TransportResponse> send(TransportRequest request) =>
      (routes[request.uri.origin] ?? otherwise).send(request);
}

/// The app's [AuthConfig] over [transport]: the demo backend over the demo server by default,
/// OpenID Connect (Keycloak) with a profile that sets `oidc.issuer` (`fsp dev --profile keycloak`).
AuthConfig authSetup(HttpTransport transport) {
  final debug = debugAuthSetup;
  if (debug != null) return debug(transport);
  if (usesOidc) {
    final issuer = Uri.parse(usesDemoOidc ? DemoServer.issuer : oidcIssuer);
    return AuthConfig(
      transport: transport,
      backend: OidcBackend(
        issuer: issuer,
        clientId: oidcClientId,
        redirectUri: Uri.parse(oidcRedirect),
        endpoints: OidcEndpoints.keycloak(issuer),
        openBrowser: usesDemoOidc ? demoBrowser : openBrowser,
        transport: transport,
        // The hardware key on Android, iOS and macOS; a software key where there is none (the web,
        // Windows, Linux: it does not survive a reload there). The default, DpopFallback.refuse,
        // throws DpopUnavailable there instead, which is what a production app that promises
        // device-bound tokens wants.
        proof: useDpop
            ? DpopProof.device(fallback: DpopFallback.software)
            : null,
      ),
      apiOrigins: [apiOrigin],
    );
  }
  return AuthConfig(
    transport: transport,
    backend: DemoBackend(apiOrigin, transport),
    apiOrigins: [apiOrigin],
  );
}

/// The browser step of the `demo` issuer: asks the demo provider for the redirect a browser would
/// follow, and returns it.
Future<Uri> demoBrowser(Uri url, Uri redirect) async {
  final response = await demoServer.client.get(url);
  return Uri.parse(response.headers['location']!);
}

/// The browser step: `flutter_web_auth_2` opens Keycloak's login page in a Custom Tab, an
/// `ASWebAuthenticationSession` or a popup, and returns the redirect. `preferEphemeral` keeps the
/// browser's single-sign-on cookie out of it, so signing out and in again asks for the password.
/// Call `signIn` straight from the button's `onPressed`: a web popup is blocked otherwise.
Future<Uri> openBrowser(Uri url, Uri redirect) async {
  try {
    return Uri.parse(
      await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: redirect.scheme,
        options: const FlutterWebAuth2Options(preferEphemeral: true),
      ),
    );
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') throw const AuthCancelled();
    rethrow;
  }
}
