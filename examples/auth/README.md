# auth

A fespalier example for [`fespalier_auth`](../../packages/fespalier_auth) (since 0.9.0): signed-in
routes, a sign-in form, guards, lazy single-flight refresh, an API client, and OpenID Connect with
Keycloak. The API is an in-process server (`lib/demo/demo_server.dart`, a `MockClient`), so the app
runs and is tested with no network.

- `lib/app/startup.dart` returns `restoreAuth(authSetup())`: the stored session is read before the
  first frame, with no network. `splash.dart` shows while the keychain answers.
- `lib/app/(signed-in)/guard.dart` is `requireSignedIn`, `(signed-in)/admin/guard.dart` is
  `requireRole`, and `lib/app/sign-in/guard.dart` is `redirectIfSignedIn`, which sends the user back
  to where they were going: the sign-in page has no navigation code.
- `lib/app/sign-in/` is a form on an action. A wrong password is the `FieldErrors` of
  `lib/demo/demo_backend.dart`, shown under its field.
- `lib/app/(signed-in)/orders/` and `orders/$id/` call the API through `authHttpClient`. Open
  `/orders/1`: the two `data.dart` files run together, and an expired token is refreshed once.
- The demo users are `ada`/`ada` (an admin) and `bob`/`bob`. Tokens live five minutes, and refresh
  tokens rotate: a second refresh with the same token would fail, which is why the refresh is a
  single flight.

## Tests

`test/` runs against the demo server on the test's fake clock: `guards_test.dart` (`fakeAuth`),
`sign_in_test.dart`, `refresh_test.dart` (one refresh for two requests, with
`tester.pump(const Duration(minutes: 6))`), `restore_test.dart` (the first frame is the app, not the
splash), `telemetry_test.dart` (the `auth` spans) and `oidc_test.dart` (`OidcBackend` against the
demo server's Keycloak-shaped provider, with PKCE checked on the server side).

## Run it against Keycloak

`keycloak/realm-fespalier.json` is an export of a realm built on Keycloak 26.8.0 (the Admin API, then
`kc.sh export --realm fespalier --users same_file`), with the realm's keys and secrets taken out
(a Keycloak that imports it makes new ones). It has the users `ada` and `bob` (password: their name),
the realm role `admin`, and two public clients with PKCE `S256` and Standard flow on, Direct access
grants off: `fespalier-auth-example`, and `fespalier-auth-example-dpop`, which requires DPoP-bound
tokens. "Revoke Refresh Token" is on, as it is in many production realms.

```sh
docker run --rm -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  -v "$PWD/keycloak:/opt/keycloak/data/import:ro" \
  quay.io/keycloak/keycloak:26.8.0 start-dev --import-realm

flutter run -d chrome --web-port 8686 \
  --dart-define=OIDC_ISSUER=http://localhost:8080/realms/fespalier
```

The sign-in page then has **Sign in with Keycloak**: `flutter_web_auth_2` opens Keycloak's login
page and the redirect (`com.example.fespalierauth:/callback` on a device,
`http://localhost:8686/auth.html` on the web) comes back with a code. The web needs `web/auth.html`
(`flutter_web_auth_2`'s README has the page); a device needs the plugin's callback activity or URL
scheme in `android/` and `ios/`, which this example, a lib-only app, does not carry. The API stays the
in-process demo, which accepts the tokens it cannot check.

- **An Android emulator reaches the host as `10.0.2.2`.** Keycloak's issuer is its configured
  hostname (`--hostname`), so start it with `--hostname=http://10.0.2.2:8080` and use
  `OIDC_ISSUER=http://10.0.2.2:8080/realms/fespalier`; with `adb reverse tcp:8080 tcp:8080` the
  emulator reaches `localhost:8080` and nothing changes. A mismatch is the error
  `the ID token was issued by ..., not ...`.
- **`preferEphemeral: true`** (in `lib/auth_setup.dart`) keeps the browser's single-sign-on cookie out
  of the sign-in, so signing out and in again asks for the password. Without it the SSO cookie signs
  the user in again silently.
- The Keycloak check of `OidcBackend` (sign-in, rotation, the `invalid_grant` descriptions,
  revocation, end session) is `packages/fespalier_auth/test/keycloak_live_test.dart`, skipped unless
  `FESPALIER_KEYCLOAK_URL` names a running Keycloak with this realm.
