# fespalier_oidc

OpenID Connect and bearer-token sessions for [fespalier_auth](https://github.com/fespalier/fespalier/blob/main/packages/fespalier_auth/README.md)
(since 0.21.0; it was `package:fespalier_auth/oidc.dart` from 0.9.0 to 0.20.0): the authorization code flow
with PKCE for a public client with Keycloak's defaults, refresh-token rotation, a `TokenCredential`, the
`BearerAuthenticator` that sends it, and the `ProofOfPossession` seam DPoP plugs into. It sends through
`fespalier_transport`'s `HttpTransport`, so it links neither `package:http` nor Dio.

The docs cover it in context:
[Authentication](https://github.com/fespalier/fespalier/blob/main/docs/auth.md). This page is the short version.

## Install

Add it next to fespalier and fespalier_auth, with the same `url` and the same `ref`: pub resolves them to one
package each only if they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.25.1
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: v0.25.1
  fespalier_oidc:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_oidc
      ref: v0.25.1
```

<!-- x-release-please-end -->

Needs Dart 3.9 and Flutter 3.35 or newer. It brings no plugin: `crypto` (PKCE) and `clock` are pure Dart.

## Wire it

```dart
// lib/auth_setup.dart
final transport = HttpClientTransport(http.Client()); // fespalier_http; or DioTransport(dio) from fespalier_dio

AuthConfig authSetup() => AuthConfig(
  transport: transport,
  backend: OidcBackend(
    issuer: Uri.parse('https://sso.example.com/realms/shop'),
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    endpoints: OidcEndpoints.keycloak(Uri.parse('https://sso.example.com/realms/shop')),
    openBrowser: openBrowser, // flutter_web_auth_2, in your app
    transport: transport,
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

Sign in with `ref.read(authSession.notifier).signIn(const BrowserSignIn())`.

## Libraries

| Library                                      | What is in it                                                                                                                                                                              |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `package:fespalier_oidc/fespalier_oidc.dart` | `OidcBackend`, `OidcEndpoints`, `TokenCredential`, `BearerAuthenticator`, `ProofOfPossession`, `BrowserSignIn`, `PasswordSignIn`, `userFromClaims`, `keycloakRoles`, `unverifiedJwtClaims` |
| `package:fespalier_oidc/testing.dart`        | `FakeProof` (a proof of possession with no crypto), `fakeTokenSession`                                                                                                                     |

## DPoP

`OidcBackend(proof: …)` is how DPoP (RFC 9449) composes in: a `ProofOfPossession` signs the token-endpoint calls
and, through the `BearerAuthenticator`, every API call, and binds the tokens to its key (`TokenCredential.jkt`).
`fespalier_keypair_dpop` makes the proofs.

Since 0.25.0 the `BearerAuthenticator` answers an RFC 9470 step-up refusal
(`error="insufficient_user_authentication"`) with `StepUp`, and `OidcBackend.stepUp` opens the browser sign-in
again for the same user with the challenge's `acr_values` and `max_age` (`prompt=login` when it names neither).
The session's `authenticatedAt` is the ID token's `auth_time` ([docs/auth.md](https://github.com/fespalier/fespalier/blob/main/docs/auth.md#step-up-authentication)).

## What it costs

No timer, no listener and no `Future.delayed` (`test/no_timers_test.dart`).
