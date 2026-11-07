//! The OpenID Provider: `authkestra-op`'s handlers, and what it leaves to its host.

use std::sync::Arc;
use std::time::Duration;

use authkestra_axum::op::{
    axum_authorize_handler, axum_jwks_handler, axum_token_handler, axum_userinfo_handler,
};
use authkestra_axum::{AxumError, SessionStore};
use authkestra_engine::oauth2::code::AuthorizationCode;
use authkestra_engine::oauth2::device::DeviceCodeSession;
use authkestra_engine::oauth2::refresh::RefreshToken;
use authkestra_engine::store::KvStore;
use authkestra_engine::store::memory::MemoryStore;
use authkestra_engine::token::dpop_nonce::DpopNonces;
use authkestra_engine::{Session, SessionConfig, TokenManager};
use authkestra_op::client::{ClientRegistration, GrantType};
use authkestra_op::handlers::discovery::OidcDiscovery;
use authkestra_op::store::CompositeOpStore;
use authkestra_op::{CloneableOpStore, DpopJtiRecord, OpConfig};
use axum::extract::{Form, FromRef, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use tower_cookies::CookieManagerLayer;

use crate::{ACCESS_TOKEN_TTL_SECS, CLIENT_ID, REDIRECT_URI};

/// What every OP handler reads, through `FromRef`.
#[derive(Clone)]
pub(crate) struct OpState {
    pub(crate) op_store: Arc<dyn CloneableOpStore>,
    pub(crate) tokens: Arc<TokenManager>,
    pub(crate) sessions: Arc<dyn SessionStore>,
    pub(crate) session_config: SessionConfig,
    pub(crate) config: OpConfig,
}

impl FromRef<OpState> for Result<Arc<dyn CloneableOpStore>, AxumError> {
    fn from_ref(state: &OpState) -> Self {
        Ok(state.op_store.clone())
    }
}

impl FromRef<OpState> for Result<Arc<TokenManager>, AxumError> {
    fn from_ref(state: &OpState) -> Self {
        Ok(state.tokens.clone())
    }
}

impl FromRef<OpState> for Result<Arc<dyn SessionStore>, AxumError> {
    fn from_ref(state: &OpState) -> Self {
        Ok(state.sessions.clone())
    }
}

impl FromRef<OpState> for SessionConfig {
    fn from_ref(state: &OpState) -> Self {
        state.session_config.clone()
    }
}

impl FromRef<OpState> for OpConfig {
    fn from_ref(state: &OpState) -> Self {
        state.config.clone()
    }
}

/// The one client: public (no secret, so PKCE is its proof), the authorization code and refresh
/// token grants, and its access tokens issued for the API's origin.
#[allow(deprecated)] // `require_pkce` (authkestra#273): PKCE is required for every client now.
fn client(api_origin: &str) -> ClientRegistration {
    ClientRegistration {
        client_id: CLIENT_ID.to_owned(),
        client_secret_hash: None,
        redirect_uris: vec![REDIRECT_URI.to_owned()],
        require_pkce: true,
        // `offline_access` is what makes `authkestra-op` issue a refresh token.
        scopes: ["openid", "profile", "email", "offline_access"]
            .map(str::to_owned)
            .to_vec(),
        grant_types: vec![GrantType::AuthorizationCode, GrantType::RefreshToken],
        allowed_audiences: vec![api_origin.to_owned()],
        token_endpoint_auth_method: None,
        jwks: None,
    }
}

pub(crate) async fn router(
    issuer: &str,
    api_origin: &str,
    tokens: Arc<TokenManager>,
) -> Result<Router, String> {
    let clients = MemoryStore::<ClientRegistration>::new();
    clients
        .set(
            CLIENT_ID,
            client(api_origin),
            Duration::from_hours(365 * 24),
        )
        .await
        .map_err(|error| error.to_string())?;
    let store = CompositeOpStore::new(
        clients,
        MemoryStore::<AuthorizationCode>::new(),
        MemoryStore::<RefreshToken>::new(),
        MemoryStore::<DeviceCodeSession>::new(),
    )
    // Without a replay store every DPoP proof is refused (it fails closed).
    .with_dpop_replay_store(MemoryStore::<DpopJtiRecord>::new())
    // RFC 9449 §8: every proof at /token must carry a nonce this server issued.
    .with_dpop_nonces(DpopNonces::random(Duration::from_secs(300)));
    let config = OpConfig {
        issuer: issuer.to_owned(),
        scopes_supported: ["openid", "profile", "email", "offline_access"]
            .map(str::to_owned)
            .to_vec(),
        response_types_supported: vec!["code".to_owned()],
        grant_types_supported: vec!["authorization_code".to_owned(), "refresh_token".to_owned()],
        id_token_signing_alg: "EdDSA".to_owned(),
        access_token_ttl_secs: ACCESS_TOKEN_TTL_SECS,
        authorization_code_ttl_secs: 60,
        device_code_ttl_secs: 600,
        token_exchange_enabled: false,
    };
    let state = OpState {
        op_store: Arc::new(store),
        tokens,
        sessions: Arc::new(MemoryStore::<Session>::new()),
        session_config: SessionConfig {
            // http://127.0.0.1 in the tests: a Secure cookie is still kept by the test's
            // browser, but say what the demo is.
            secure: false,
            ..SessionConfig::default()
        },
        config,
    };
    Ok(Router::new()
        .route("/.well-known/openid-configuration", get(discovery))
        .route("/jwks.json", get(axum_jwks_handler::<OpState>))
        .route("/authorize", get(axum_authorize_handler::<OpState>))
        .route("/token", post(axum_token_handler::<OpState>))
        .route(
            "/userinfo",
            get(axum_userinfo_handler::<OpState>).post(axum_userinfo_handler::<OpState>),
        )
        .route("/revoke", post(revoke))
        .route("/login", post(crate::login::login))
        .layer(CookieManagerLayer::new())
        .with_state(state))
}

/// `authkestra-op`'s discovery document, with the two things it advertises only when its host
/// opts in: DPoP (this OP has a replay store, so it accepts proofs) and the revocation
/// endpoint this server mounts.
async fn discovery(State(config): State<OpConfig>) -> Json<OidcDiscovery> {
    let revoke = format!("{}/revoke", config.issuer);
    Json(
        OidcDiscovery::from_config(&config)
            .with_dpop_support()
            .with_revocation_endpoint(revoke),
    )
}

#[derive(Deserialize)]
pub(crate) struct RevokeForm {
    token: Option<String>,
    client_id: Option<String>,
}

/// RFC 7009 revocation of a refresh token, for the public client (its `client_id` is its whole
/// authentication). `authkestra-op` ships no revocation handler; its refresh-token store has
/// `revoke_token`. A token that is unknown, already revoked, an access token (a JWT, which
/// lives until it expires) or another client's is answered 200 and left alone (§2.2).
async fn revoke(State(state): State<OpState>, Form(form): Form<RevokeForm>) -> Response {
    let (Some(token), Some(client_id)) = (form.token, form.client_id) else {
        return oauth_error(StatusCode::BAD_REQUEST, "invalid_request");
    };
    let mut store = state.op_store.clone_op_store();
    match store.find_client(&client_id).await {
        Ok(Some(_)) => {}
        Ok(None) => return oauth_error(StatusCode::UNAUTHORIZED, "invalid_client"),
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
    match store.get_token(&token).await {
        Ok(Some(found)) if found.client_id == client_id => {
            if store.revoke_token(&token).await.is_err() {
                return StatusCode::SERVICE_UNAVAILABLE.into_response();
            }
        }
        Ok(_) => {}
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
    StatusCode::OK.into_response()
}

fn oauth_error(status: StatusCode, error: &str) -> Response {
    (status, Json(serde_json::json!({ "error": error }))).into_response()
}
