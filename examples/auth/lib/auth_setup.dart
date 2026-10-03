import 'package:auth/api.dart';
import 'package:auth/demo/demo_backend.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/oidc.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

/// Sign in with a Keycloak instead of the demo API: `--dart-define=OIDC_ISSUER=http://localhost:8080/realms/fespalier`
/// (the realm of `keycloak/realm-fespalier.json`; on an Android emulator the host is `10.0.2.2`,
/// which Keycloak must be told is its hostname: see the README).
const String oidcIssuer = String.fromEnvironment('OIDC_ISSUER');

/// The Keycloak client: `fespalier-auth-example`.
const String oidcClientId = String.fromEnvironment(
  'OIDC_CLIENT_ID',
  defaultValue: 'fespalier-auth-example',
);

/// Where Keycloak sends the browser back to: registered with the client.
const String oidcRedirect = String.fromEnvironment(
  'OIDC_REDIRECT',
  defaultValue: 'com.example.fespalierauth:/callback',
);

/// `--dart-define=OIDC_ISSUER=demo` signs in with OpenID Connect against the demo server's own
/// provider (shaped like Keycloak, in process): no Keycloak, no browser, no network.
const String demoIssuer = 'demo';

/// `--dart-define=DPOP=true` binds the tokens to a device key (DPoP, RFC 9449). Needs
/// `OIDC_ISSUER`; against Keycloak use the client `fespalier-auth-example-dpop`
/// (`--dart-define=OIDC_CLIENT_ID=fespalier-auth-example-dpop`), which requires DPoP-bound tokens.
const bool useDpop = bool.fromEnvironment('DPOP');

/// Whether the app signs in with OpenID Connect.
bool get usesOidc => oidcIssuer.isNotEmpty;

/// Whether that provider is the demo server's own.
bool get usesDemoOidc => oidcIssuer == demoIssuer;

/// The API the app talks to, in process: the demo server. With a real Keycloak it takes any token,
/// because the tokens are Keycloak's, which it cannot ask; with its own provider it checks them,
/// and the DPoP proofs when `DPOP` is on.
final DemoServer demoServer = DemoServer(
  latency: const Duration(milliseconds: 250),
  trustAnyToken: usesOidc && !usesDemoOidc,
  requireDpop: useDpop && usesDemoOidc,
);

/// A test swaps in its own [AuthConfig] (and, with [debugApiClient], its own API).
@visibleForTesting
AuthConfig Function()? debugAuthSetup;

/// A test swaps in the client the API is reached through.
@visibleForTesting
http.Client Function()? debugApiClient;

/// The client `authHttpClient` sends through: the demo server's. In your app it is the default,
/// a real `http.Client`, and you do not override `authBaseClient` at all.
http.Client apiClient() => (debugApiClient ?? () => demoServer.client)();

/// The app's [AuthConfig]: the demo backend over the demo server by default, OpenID Connect
/// (Keycloak) with `--dart-define=OIDC_ISSUER=...`.
AuthConfig authSetup() {
  final debug = debugAuthSetup;
  if (debug != null) return debug();
  if (usesOidc) {
    final issuer = Uri.parse(usesDemoOidc ? DemoServer.issuer : oidcIssuer);
    return AuthConfig(
      backend: OidcBackend(
        issuer: issuer,
        clientId: oidcClientId,
        redirectUri: Uri.parse(oidcRedirect),
        endpoints: OidcEndpoints.keycloak(issuer),
        openBrowser: usesDemoOidc ? demoBrowser : openBrowser,
        client: usesDemoOidc ? demoServer.client : null,
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
    backend: DemoBackend(apiOrigin, demoServer.client),
    apiOrigins: [apiOrigin],
  );
}

/// The browser step of `OIDC_ISSUER=demo`: asks the demo provider for the redirect a browser would
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
