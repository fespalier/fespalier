//! The one route the end-to-end tests need that no client may have: an operator revoking a device
//! (`fespalier_cratestack`'s revocation-with-queued-intents test revokes a device while the app is
//! offline). It exists only when the server is started with `--test-hooks`, it is **not in the
//! schema** (so the generated client has no such call), and it is a route of its own merged next
//! to the generated router, not a layer in front of it.
//!
//! `POST /test/revoke` with the JSON body `{"deviceId": "..."}`: `204` when the device was
//! revoked, `404` when there is no such device.

use std::sync::Arc;

use cratestack::axum::Router;
use cratestack::axum::body::Bytes;
use cratestack::axum::extract::State;
use cratestack::axum::http::StatusCode;
use cratestack::axum::routing::post;
use cratestack::serde_json::{self, Value};

use crate::Shared;

/// The route, over the server's state.
pub fn routes(shared: Arc<Shared>) -> Router {
    Router::new()
        .route("/test/revoke", post(revoke))
        .with_state(shared)
}

async fn revoke(State(shared): State<Arc<Shared>>, body: Bytes) -> StatusCode {
    let device = serde_json::from_slice::<Value>(&body)
        .ok()
        .and_then(|value| value.get("deviceId")?.as_str().map(str::to_owned));
    match device {
        Some(id) if shared.revoke(&id) => StatusCode::NO_CONTENT,
        Some(_) => StatusCode::NOT_FOUND,
        None => StatusCode::BAD_REQUEST,
    }
}
