/// OpenID Connect for `fespalier_auth` (since 0.9.0): the authorization code flow with PKCE for a
/// public client, with Keycloak's defaults, in pure Dart over `package:http`.
///
/// ```dart
/// AuthConfig authSetup() => AuthConfig(
///   backend: OidcBackend(
///     issuer: Uri.parse('https://sso.example.com/realms/shop'),
///     clientId: 'shop-app',
///     redirectUri: Uri.parse('com.example.shop:/callback'),
///     endpoints: OidcEndpoints.keycloak(Uri.parse('https://sso.example.com/realms/shop')),
///     openBrowser: openBrowser, // flutter_web_auth_2, in your app
///   ),
///   apiOrigins: [Uri.parse('https://api.example.com')],
/// );
/// ```
///
/// A separate library, so an app that signs in some other way (Firebase, Supabase, its own API)
/// links none of it.
library;

export 'src/oidc/endpoints.dart' show OidcEndpoints;
export 'src/oidc/exception.dart' show OidcException;
export 'src/oidc/oidc_backend.dart' show OidcBackend, OpenBrowser;
export 'src/oidc/roles.dart' show keycloakRoles;
