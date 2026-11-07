//! The parts of the server that are this crate's, not `authkestra-op`'s: the discovery opt-ins,
//! the demo login, the revocation endpoint and the API's refusals. The flows (sign-in, DPoP,
//! nonces, renewal, sign-out) run from Dart, against the binary:
//! `packages/fespalier_keypair_dpop/test/authkestra_op_test.dart`.

#![allow(clippy::expect_used, reason = "a test fails on what it did not expect")]

use authkestra_op_demo_server::{CLIENT_ID, PASSWORD, REDIRECT_URI, Servers, USERNAME, build};
use axum::body::Body;
use axum::http::{Request, StatusCode, header};
use axum::response::Response;
use http_body_util::BodyExt;
use tower::ServiceExt;

const ISSUER: &str = "http://127.0.0.1:1";
const API: &str = "http://127.0.0.1:2";

async fn servers() -> Servers {
    build(ISSUER, API).await.expect("the servers build")
}

async fn json(response: Response) -> serde_json::Value {
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("a body")
        .to_bytes();
    serde_json::from_slice(&bytes).expect("JSON")
}

fn form(uri: &str, body: &str) -> Request<Body> {
    Request::post(uri)
        .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
        .body(Body::from(body.to_owned()))
        .expect("a request")
}

#[tokio::test]
async fn discovery_advertises_pkce_dpop_and_the_revocation_endpoint() {
    let response = servers()
        .await
        .op
        .oneshot(
            Request::get("/.well-known/openid-configuration")
                .body(Body::empty())
                .expect("a request"),
        )
        .await
        .expect("an answer");
    assert_eq!(response.status(), StatusCode::OK);
    let doc = json(response).await;
    assert_eq!(doc["issuer"], ISSUER);
    assert_eq!(doc["authorization_endpoint"], format!("{ISSUER}/authorize"));
    assert_eq!(doc["token_endpoint"], format!("{ISSUER}/token"));
    assert_eq!(doc["revocation_endpoint"], format!("{ISSUER}/revoke"));
    assert_eq!(
        doc["code_challenge_methods_supported"],
        serde_json::json!(["S256"])
    );
    assert!(
        doc["dpop_signing_alg_values_supported"]
            .as_array()
            .is_some_and(|algs| algs.contains(&serde_json::json!("ES256")))
    );
    assert!(doc.get("end_session_endpoint").is_none());
}

#[tokio::test]
async fn authorize_asks_for_the_login_and_then_redirects_with_a_code() {
    let op = servers().await.op;
    let authorize = format!(
        "/authorize?client_id={CLIENT_ID}&redirect_uri={REDIRECT_URI}&response_type=code\
         &scope=openid&state=s1&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM\
         &code_challenge_method=S256"
    );
    let anonymous = op
        .clone()
        .oneshot(
            Request::get(&authorize)
                .body(Body::empty())
                .expect("a request"),
        )
        .await
        .expect("an answer");
    assert_eq!(anonymous.headers()[header::LOCATION], "/login");

    let wrong = op
        .clone()
        .oneshot(form(
            "/login",
            &format!("username={USERNAME}&password=nope"),
        ))
        .await
        .expect("an answer");
    assert_eq!(wrong.status(), StatusCode::UNAUTHORIZED);

    let login = op
        .clone()
        .oneshot(form(
            "/login",
            &format!("username={USERNAME}&password={PASSWORD}"),
        ))
        .await
        .expect("an answer");
    assert_eq!(login.status(), StatusCode::NO_CONTENT);
    let cookie = login.headers()[header::SET_COOKIE]
        .to_str()
        .expect("ASCII")
        .split(';')
        .next()
        .expect("a pair")
        .to_owned();

    let signed_in = op
        .oneshot(
            Request::get(&authorize)
                .header(header::COOKIE, cookie)
                .body(Body::empty())
                .expect("a request"),
        )
        .await
        .expect("an answer");
    let location = signed_in.headers()[header::LOCATION]
        .to_str()
        .expect("ASCII");
    assert!(
        location.starts_with(&format!("{REDIRECT_URI}?code=")),
        "{location}"
    );
    assert!(location.ends_with("&state=s1"), "{location}");
}

#[tokio::test]
async fn revocation_answers_200_for_a_token_it_does_not_know_and_refuses_a_missing_client() {
    let op = servers().await.op;
    let unknown = op
        .clone()
        .oneshot(form(
            "/revoke",
            &format!("token=nope&client_id={CLIENT_ID}"),
        ))
        .await
        .expect("an answer");
    assert_eq!(unknown.status(), StatusCode::OK);

    let anonymous = op
        .clone()
        .oneshot(form("/revoke", "token=nope"))
        .await
        .expect("an answer");
    assert_eq!(anonymous.status(), StatusCode::BAD_REQUEST);

    let stranger = op
        .oneshot(form("/revoke", "token=nope&client_id=someone-else"))
        .await
        .expect("an answer");
    assert_eq!(stranger.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(json(stranger).await["error"], "invalid_client");
}

#[tokio::test]
async fn the_api_refuses_a_request_without_a_token_with_a_dpop_challenge_and_a_nonce() {
    let response = servers()
        .await
        .api
        .oneshot(
            Request::get("/api/me")
                .body(Body::empty())
                .expect("a request"),
        )
        .await
        .expect("an answer");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let challenge = response.headers()[header::WWW_AUTHENTICATE]
        .to_str()
        .expect("ASCII");
    assert!(challenge.starts_with("DPoP "), "{challenge}");
    assert!(challenge.contains("error=\"invalid_token\""), "{challenge}");
    assert!(response.headers().contains_key("dpop-nonce"));
}
