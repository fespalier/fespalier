# authkestra-op: fespalier_oidc against Authkestra

A server for a test, not an app. `server/` is an [Authkestra](https://github.com/Authkestra/authkestra) OpenID
Provider, `authkestra-op`, taken from git at one commit (`server/Cargo.toml`: crates.io's 0.14.0 has no DPoP nonce),
and an API that accepts DPoP-bound tokens only. [`packages/fespalier_keypair_dpop/test/authkestra_op_test.dart`](../../packages/fespalier_keypair_dpop/test/authkestra_op_test.dart)
starts it and signs in with the stack an app runs: `OidcBackend` (`fespalier_oidc`), `DpopProof` over a real ES256
key (`fespalier_keypair_dpop`), the session notifier and `SessionTransport` (`fespalier_auth`). CI's `authkestra-op`
job runs both; `docs/auth.md` ("OpenID Connect with Authkestra") is what an app needs to know.

## What the server serves

Everything is in memory; the token signing key (Ed25519) is new at every start.

| Origin | Route                                    | Whose code                                                                                                                                                                                                                                                                                 |
| ------ | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| issuer | `GET /.well-known/openid-configuration`  | `authkestra-op`'s `OidcDiscovery`, with its two opt-ins: `with_dpop_support` and `with_revocation_endpoint`                                                                                                                                                                                |
| issuer | `GET /authorize`                         | `authkestra-op` (PKCE S256 required); with no session it redirects to `/login`                                                                                                                                                                                                             |
| issuer | `POST /token`                            | `authkestra-op`: the code and refresh-token grants, DPoP-bound tokens, a `DPoP-Nonce` required on every proof (`CompositeOpStore::with_dpop_nonces`)                                                                                                                                       |
| issuer | `GET /jwks.json`, `GET`/`POST /userinfo` | `authkestra-op`                                                                                                                                                                                                                                                                            |
| issuer | `POST /revoke`                           | this crate: RFC 7009 for the public client, over the OP's refresh-token store (`authkestra-op` ships no revocation handler)                                                                                                                                                                |
| issuer | `POST /login`                            | this crate: the demo login, one user (`ada` / `ada`); it opens the engine session `/authorize` reads                                                                                                                                                                                       |
| API    | `GET /api/me`                            | Authkestra's resource-side `JwtStrategy` (signature against `/jwks.json`, issuer, audience, the DPoP proof and its key against `cnf.jkt`, a `jti` seen once), then a nonce of the API's own (Authkestra's `DpopNonces`): `401`, `WWW-Authenticate: DPoP error="use_dpop_nonce"` without it |

The API has its own origin (a second port) so that each side has its own nonce, as a client keeps one per origin.

The client is `fespalier-oidc-example`: public, redirect URI `com.example.fespalier:/callback`, scopes `openid
profile email offline_access` (`offline_access` is what makes `authkestra-op` issue a refresh token), access tokens
issued for the API's origin.

```sh
cd server && cargo run --locked
# {"issuer":"http://127.0.0.1:PORT","api":"http://127.0.0.1:PORT2","client_id":"fespalier-oidc-example",...}
```

`--listen` and `--api-listen` take an address (`127.0.0.1:0`, the default, picks a free port); the first line on
stdout is the JSON above, and the issuer is the address the OP was bound to.

## The test

```sh
cd server && cargo build --locked
cd ../../../packages/fespalier_keypair_dpop
AUTHKESTRA_OP_BIN=../../examples/authkestra-op/server/target/debug/authkestra-op-demo-server \
  flutter test test/authkestra_op_test.dart
```

Without `AUTHKESTRA_OP_BIN` the file skips, saying why (the `dart` job runs it so); with `FSP_REQUIRE_AUTHKESTRA_OP=1`
a missing binary fails instead. `just authkestra-op` runs the server's gates (`just authkestra-op-server`: fmt, clippy,
`cargo test`, a locked build, `cargo deny`) and then the test, required. What it checks:

- `OidcEndpoints.discover` finds the authorization, token and revocation endpoints and ES256 among the DPoP
  algorithms (there is no end-session endpoint);
- the sign-in is the code flow with PKCE S256, and the code exchange is two POSTs: `400 use_dpop_nonce` with a
  `DPoP-Nonce`, then `200` with a proof that carries it; the tokens are `DPoP`, bound to the key (`cnf.jkt`), issued
  for the API;
- a call through `SessionTransport` to `/api/me`: the API's `use_dpop_nonce` is one `Resend`, the next call reuses the
  nonce, and the token with the `Bearer` scheme or without a proof is refused;
- a renewal rotates the refresh token, keeps the key, and the old refresh token is `invalid_grant`;
- a refresh token is refused for another key (`invalid_dpop_proof`, the end of the session);
- the sign-out revokes the refresh token at `/revoke`, after which it is `invalid_grant`.

`server/tests/server.rs` checks what is this crate's own: the discovery opt-ins, the login and the redirect with a
code, the revocation endpoint's refusals and the API's challenge.

## Not checked

- **A real browser.** The test's "browser" is two HTTP requests: it posts the demo `/login` and opens the authorization
  URL again with the session cookie, and reads the redirect. `flutter_web_auth_2`, a person typing and a login page of
  a real host are not run.
- **A device key.** The proofs are signed by `FakeKeypairSigner` (a real ES256 key from a fixed scalar), not by the
  Secure Enclave or the AndroidKeyStore.
- **Step-up against Authkestra.** `authkestra-op` sends no RFC 9470 challenge, and the example's API asks for none.
- **What `authkestra-op` differs on** is in `docs/auth.md`: the user's attributes in an `identity` object instead of
  OpenID Connect's standard claims, `dpop_jkt` ignored at `/authorize`, no end-session endpoint.
