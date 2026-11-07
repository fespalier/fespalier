//! The API: one route that takes a DPoP-bound access token, checked by Authkestra's own
//! resource-side `JwtStrategy`, and a DPoP nonce of its own.

use std::sync::Arc;
use std::time::Duration;

use authkestra_engine::store::memory::MemoryStore;
use authkestra_engine::strategy::AuthenticationStrategy;
use authkestra_engine::token::dpop_nonce::{DPOP_NONCE_HEADER, DpopNonces, dpop_proof_nonce};
use authkestra_resource::DpopJtiRecord;
use authkestra_resource::jwt::{JwtStrategy, ValidationConfig};
use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use jsonwebtoken::Algorithm;
use serde::Deserialize;

/// The access token claims `/api/me` answers with.
#[derive(Deserialize)]
struct Claims {
    sub: String,
    scope: Option<String>,
    cnf: Option<serde_json::Value>,
}

#[derive(Clone)]
struct ApiState {
    strategy: Arc<JwtStrategy<Claims>>,
    /// This API's nonces: another secret than the OP's, so a nonce from `/token` is not one of
    /// them (a client keeps one per origin anyway).
    nonces: Arc<DpopNonces>,
}

pub(crate) fn router(issuer: &str, api_origin: &str) -> Router {
    let config = ValidationConfig::builder()
        .jwks_url(format!("{issuer}/jwks.json"))
        .issuer(issuer)
        .audience(api_origin)
        .algorithms(vec![Algorithm::EdDSA])
        // RFC 9449 at the resource: the `DPoP` scheme, a proof for this method and URL with
        // `ath`, its key the token's `cnf.jkt`, and its `jti` seen once.
        .require_dpop(true)
        .dpop_resource_origin(api_origin)
        .build();
    let strategy = JwtStrategy::new(config)
        .with_dpop_replay_store(Arc::new(MemoryStore::<DpopJtiRecord>::new()));
    let state = ApiState {
        strategy: Arc::new(strategy),
        nonces: Arc::new(DpopNonces::random(Duration::from_secs(300))),
    };
    Router::new().route("/api/me", get(me)).with_state(state)
}

async fn me(State(state): State<ApiState>, request: Request<Body>) -> Response {
    let (parts, _) = request.into_parts();
    let claims = match state.strategy.authenticate(&parts).await {
        Ok(Some(claims)) => claims,
        Ok(None) => {
            return challenge(
                &state,
                "invalid_token",
                "The access token or its DPoP proof is not valid",
            );
        }
        Err(_) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
    };
    // After the strategy, so the nonce read here is covered by a signature it checked (the
    // order `authkestra-op` keeps at /token).
    let nonce = parts
        .headers
        .get("dpop")
        .and_then(|value| value.to_str().ok())
        .and_then(dpop_proof_nonce);
    if !nonce.is_some_and(|nonce| state.nonces.accepts(&nonce)) {
        return challenge(
            &state,
            "use_dpop_nonce",
            "Resource server requires nonce in DPoP proof",
        );
    }
    let jkt = claims
        .cnf
        .as_ref()
        .and_then(|cnf| cnf.get("jkt"))
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    let body = serde_json::json!({ "sub": claims.sub, "scope": claims.scope, "jkt": jkt });
    with_nonce(&state, (StatusCode::OK, Json(body)).into_response())
}

/// A `401` with a DPoP challenge (RFC 9449 §7.1) and a fresh nonce.
fn challenge(state: &ApiState, error: &str, description: &str) -> Response {
    let value =
        format!("DPoP error=\"{error}\", error_description=\"{description}\", algs=\"ES256\"");
    let mut response = StatusCode::UNAUTHORIZED.into_response();
    if let Ok(value) = HeaderValue::from_str(&value) {
        response
            .headers_mut()
            .insert(header::WWW_AUTHENTICATE, value);
    }
    with_nonce(state, response)
}

/// Every answer carries the current nonce (RFC 9449 §9), as `authkestra-op`'s /token does.
fn with_nonce(state: &ApiState, mut response: Response) -> Response {
    if let Ok(value) = HeaderValue::from_str(&state.nonces.issue()) {
        response.headers_mut().insert(DPOP_NONCE_HEADER, value);
    }
    response
}
