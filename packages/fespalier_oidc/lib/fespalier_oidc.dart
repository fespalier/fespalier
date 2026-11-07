/// OpenID Connect for `fespalier_auth` (since 0.9.0 as `package:fespalier_auth/oidc.dart`; its own
/// package since 0.21.0): the authorization code flow with PKCE for a public client, with
/// Keycloak's defaults, and any token backend (a `TokenCredential` and the `BearerAuthenticator`
/// that sends it), and (since 0.27.0) the device authorization grant of RFC 8628 for a TV or a
/// kiosk (`DeviceSignIn`). It sends through `package:fespalier_transport`, so it links neither
/// `package:http` nor Dio.
///
/// ```dart
/// final transport = HttpClientTransport(http.Client()); // or DioTransport(dio)
///
/// AuthConfig authSetup() => AuthConfig(
///   transport: transport,
///   backend: OidcBackend(
///     issuer: Uri.parse('https://sso.example.com/realms/shop'),
///     clientId: 'shop-app',
///     redirectUri: Uri.parse('com.example.shop:/callback'),
///     endpoints: OidcEndpoints.keycloak(Uri.parse('https://sso.example.com/realms/shop')),
///     openBrowser: openBrowser, // flutter_web_auth_2, in your app
///     transport: transport,
///   ),
///   apiOrigins: [Uri.parse('https://api.example.com')],
/// );
/// ```
///
/// A separate package, so an app that signs in some other way (Firebase, Supabase, its own API, a
/// device key) links none of it. DPoP composes in through `OidcBackend(proof: …)`:
/// `package:fespalier_keypair_dpop` makes the proofs.
library;

export 'src/bearer_authenticator.dart' show BearerAuthenticator;
export 'src/device_sign_in.dart' show DeviceCode, DeviceSignIn, DeviceWait;
export 'src/endpoints.dart' show OidcEndpoints;
export 'src/exception.dart' show OidcException;
export 'src/jwt.dart' show unverifiedJwtClaims;
export 'src/oidc_backend.dart' show OidcBackend, OpenBrowser;
export 'src/proof.dart' show ProofOfPossession;
export 'src/roles.dart' show keycloakRoles;
export 'src/sign_in.dart' show BrowserSignIn, PasswordSignIn;
export 'src/token_credential.dart' show TokenCredential;
export 'src/user.dart' show userFromClaims, volatileClaims;
