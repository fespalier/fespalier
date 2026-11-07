//! The demo login: what a host application's own `/login` does before `authkestra-op`'s
//! `/authorize` can answer, reduced to one fixed user.
//!
//! `/authorize` reads the engine session from its cookie and, with none, redirects to `/login`.
//! `POST /login` with `username=ada&password=ada` opens that session and sets the cookie; the
//! browser then opens the authorization URL again. A real host would show a form and send the
//! browser back on its own; the tests' headless browser posts the form and reopens the URL.

use std::collections::HashMap;

use authkestra_engine::Session;
use authkestra_engine::auth::state::{IDENTITY_ATTR_AUTH_TIME, Identity};
use axum::extract::{Form, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use tower_cookies::Cookies;

use crate::op::OpState;
use crate::{PASSWORD, USERNAME};

#[derive(Deserialize)]
pub(crate) struct LoginForm {
    username: String,
    password: String,
}

pub(crate) async fn login(
    State(state): State<OpState>,
    cookies: Cookies,
    Form(form): Form<LoginForm>,
) -> Response {
    if form.username != USERNAME || form.password != PASSWORD {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(id) = crate::random_id() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let now = chrono::Utc::now();
    let identity = Identity {
        provider_id: "demo".to_owned(),
        external_id: USERNAME.to_owned(),
        email: Some(format!("{USERNAME}@example.com")),
        username: Some(USERNAME.to_owned()),
        // What `max_age` is checked against, and the ID token's `auth_time`.
        attributes: HashMap::from([(
            IDENTITY_ATTR_AUTH_TIME.to_owned(),
            now.timestamp().to_string(),
        )]),
    };
    let session = Session::new(id.clone(), identity, now + chrono::Duration::hours(1));
    if state.sessions.save_session(&session).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    cookies.add(authkestra_axum::helpers::cookie::create_axum_cookie(
        &state.session_config,
        id,
    ));
    StatusCode::NO_CONTENT.into_response()
}
