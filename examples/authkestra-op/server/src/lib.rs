//! The server of fespalier's `authkestra-op` example: what `fespalier_oidc` and
//! `fespalier_keypair_dpop` are tested against in CI (`packages/fespalier_keypair_dpop/test/authkestra_op_test.dart`).
//!
//! Two routers, served on two origins so that each has its own DPoP nonce (a client keeps one
//! nonce per origin, RFC 9449 §8):
//!
//! - **The OpenID Provider** ([`op`]): Authkestra's own `authkestra-op` handlers for
//!   `/authorize` (PKCE S256 only), `/token` (authorization code and refresh token, DPoP-bound,
//!   with a `DPoP-Nonce` required on every proof) and `/jwks.json`. Around them, what
//!   `authkestra-op` leaves to its host: the discovery document built with Authkestra's own
//!   `OidcDiscovery` and its opt-ins (`with_dpop_support`, `with_revocation_endpoint`), an RFC
//!   7009 `/revoke` over the OP's refresh-token store, and a demo `/login` that opens the
//!   session `/authorize` reads (one user, `ada`/`ada`: the headless browser of the tests posts
//!   it, as a person would type it).
//! - **The API** ([`api`]): `GET /api/me`, which accepts a DPoP-bound access token only.
//!   Authkestra's resource-side `JwtStrategy` checks the token (its signature against the OP's
//!   JWKS, issuer, audience) and the proof (`htm`, `htu`, `iat`, `ath`, the key against the
//!   token's `cnf.jkt`, a `jti` seen once), and then the proof must carry this API's own nonce
//!   (Authkestra's `DpopNonces`), else a `401` with `WWW-Authenticate: DPoP error="use_dpop_nonce"`.
//!
//! Everything is in memory and lives as long as the process; the token signing key is new on
//! every start. Nothing here is a production deployment: the login is a fixed user.

mod api;
mod login;
mod op;

use std::sync::Arc;

use authkestra_engine::TokenManager;
use axum::Router;

/// The public client the example registers (no secret: PKCE).
pub const CLIENT_ID: &str = "fespalier-oidc-example";

/// Where `/authorize` sends the browser back to: the app's custom scheme.
pub const REDIRECT_URI: &str = "com.example.fespalier:/callback";

/// The one demo user's name and password.
pub const USERNAME: &str = "ada";

/// See [`USERNAME`].
pub const PASSWORD: &str = "ada";

/// How long an access token lives, in seconds.
pub const ACCESS_TOKEN_TTL_SECS: u64 = 300;

/// The two routers [`build`] makes.
pub struct Servers {
    /// The OpenID Provider, to serve at the issuer.
    pub op: Router,
    /// The API, to serve at its own origin.
    pub api: Router,
}

/// The OP for `issuer` (`http://127.0.0.1:PORT`, no trailing slash) and the API at `api_origin`,
/// whose access tokens are issued for that origin (`aud`).
///
/// # Errors
///
/// When the token signing key cannot be made or the client cannot be registered.
pub async fn build(issuer: &str, api_origin: &str) -> Result<Servers, String> {
    let tokens = Arc::new(signing_key(issuer)?);
    Ok(Servers {
        op: op::router(issuer, api_origin, tokens).await?,
        api: api::router(issuer, api_origin),
    })
}

/// A fresh Ed25519 key per start: the API verifies the tokens against the OP's `/jwks.json`, so
/// nothing outside the process needs to know it.
fn signing_key(issuer: &str) -> Result<TokenManager, String> {
    use ed25519_dalek::pkcs8::EncodePrivateKey;
    let mut seed = [0u8; 32];
    getrandom::fill(&mut seed).map_err(|error| error.to_string())?;
    let key = ed25519_dalek::SigningKey::from_bytes(&seed);
    let pem = key
        .to_pkcs8_pem(ed25519_dalek::pkcs8::spki::der::pem::LineEnding::LF)
        .map_err(|error| error.to_string())?;
    TokenManager::new_ed25519(pem.as_bytes(), Some(issuer.to_owned()), None)
        .map_err(|error| error.to_string())
}

/// A random URL-safe value of 32 bytes (session ids).
pub(crate) fn random_id() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
    Ok(bytes.iter().fold(String::with_capacity(64), |mut out, b| {
        use std::fmt::Write as _;
        let _ = write!(out, "{b:02x}");
        out
    }))
}
