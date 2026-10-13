//! The server over the wire, in process: what a signed client gets, and every way a request is
//! refused. Requests are sealed with `cratestack-cose`'s own sealer.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

mod support;

use cose_demo_server::cratestack_schema;
use cratestack::axum::body::Body;
use cratestack::axum::http::{Method, Request, StatusCode, header};
use cratestack::serde_json::{Value, json};
use cratestack::{ContractSelector, find_contract};
use support::{CBOR, Device, SIGN1, cbor, from_cbor, plain, send, world};

const UNAUTHENTICATED: &str = "request could not be authenticated";

fn error_message(body: &[u8]) -> String {
    from_cbor(body)["message"]
        .as_str()
        .expect("message")
        .to_owned()
}

#[tokio::test]
async fn register_then_a_signed_write_and_a_signed_read_succeed_and_are_sealed() {
    let world = world();
    let device = Device::new(&world, 0x21, 0);

    let registered = device.register(&world).await;
    assert_eq!(registered.status, StatusCode::OK);
    assert!(!registered.is_sealed(), "registerDevice is plain");
    assert_eq!(registered.content_type(), CBOR);
    let view = from_cbor(&registered.body);
    let kid = device.signer.verify_key().kid();
    assert_eq!(view["kid"], support::hex(&kid));
    assert_eq!(world.built.devices.len(), 1);

    let write = device
        .call("procedure.addNote", &json!({ "args": { "text": "first" } }))
        .send(&world)
        .await;
    assert_eq!(write.answer.status, StatusCode::OK);
    assert!(write.answer.is_sealed(), "{}", write.answer.content_type());
    assert_eq!(write.open().await, json!({ "id": 1, "text": "first" }));

    let read = device
        .call("procedure.listNotes", &json!({ "args": {} }))
        .send(&world)
        .await;
    assert_eq!(read.answer.status, StatusCode::OK);
    assert!(read.answer.is_sealed());
    assert_eq!(
        read.open().await,
        json!({ "notes": [{ "id": 1, "text": "first" }] })
    );
}

#[tokio::test]
async fn a_signed_write_under_an_idempotency_key_is_bound_and_sealed() {
    let world = world();
    let device = Device::new(&world, 0x22, 0);
    device.register(&world).await;
    let write = device
        .call("procedure.addNote", &json!({ "args": { "text": "keyed" } }))
        .header("idempotency-key", "k-1")
        .send(&world)
        .await;
    // The key is in the AAD: `open` rebuilds the response binding with it, so this only
    // verifies if the server bound the very same header.
    assert_eq!(
        write.answer.status,
        StatusCode::OK,
        "{:?}",
        write.answer.body
    );
    write.open().await;
}

#[tokio::test]
async fn one_device_cannot_read_another_ones_notes() {
    let world = world();
    let (alice, bob) = (Device::new(&world, 0x23, 0), Device::new(&world, 0x24, 0));
    alice.register(&world).await;
    bob.register(&world).await;
    alice
        .call("procedure.addNote", &json!({ "args": { "text": "mine" } }))
        .send(&world)
        .await;
    let read = bob
        .call("procedure.listNotes", &json!({ "args": {} }))
        .send(&world)
        .await;
    assert_eq!(read.answer.status, StatusCode::OK);
    assert_eq!(read.open().await, json!({ "notes": [] }));
}

#[tokio::test]
async fn a_refused_call_by_a_registered_device_is_still_sealed() {
    let world = world();
    let device = Device::new(&world, 0x25, 0);
    device.register(&world).await;
    // `text` is missing: the handler is never reached, the answer is a signed 4xx.
    let bad = device
        .call("procedure.addNote", &json!({ "args": {} }))
        .send(&world)
        .await;
    assert!(bad.answer.status.is_client_error(), "{}", bad.answer.status);
    assert!(bad.answer.is_sealed());
    bad.open().await;
}

#[tokio::test]
async fn a_signed_call_naming_its_contract_selector_is_accepted() {
    let world = world();
    let device = Device::new(&world, 0x26, 0);
    device.register(&world).await;
    let digest = find_contract(
        cratestack_schema::OP_CONTRACTS,
        "POST",
        "procedure.listNotes",
    )
    .expect("digest");
    let call = device
        .call("procedure.listNotes", &json!({ "args": {} }))
        .header(
            "cratestack-contract",
            ContractSelector::of(digest).to_header_value(),
        );
    let exchange = call.send(&world).await;
    assert_eq!(exchange.answer.status, StatusCode::OK);
    exchange.open().await;
}

#[tokio::test]
async fn a_selector_naming_no_accepted_contract_is_426() {
    let world = world();
    let device = Device::new(&world, 0x27, 0);
    device.register(&world).await;
    let exchange = device
        .call("procedure.listNotes", &json!({ "args": {} }))
        .header(
            "cratestack-contract",
            ContractSelector::of(&[0xab; 32]).to_header_value(),
        )
        .send(&world)
        .await;
    assert_eq!(exchange.answer.status, StatusCode::UPGRADE_REQUIRED);
    assert!(
        !exchange.answer.is_sealed(),
        "the layer's own refusals are unsigned"
    );
}

#[tokio::test]
async fn a_signed_call_with_accept_json_is_still_answered_sealed() {
    let world = world();
    let device = Device::new(&world, 0x28, 0);
    device.register(&world).await;
    let (sealed, mut request) = device
        .call("procedure.listNotes", &json!({ "args": {} }))
        .seal()
        .await;
    request
        .headers_mut()
        .insert(header::ACCEPT, "application/json".parse().expect("value"));
    let answer = send(&world.router, request).await;
    assert_eq!(answer.status, StatusCode::OK);
    assert!(answer.is_sealed());
    let _ = sealed;
}

#[tokio::test]
async fn a_key_nobody_registered_is_401_and_unsigned() {
    let world = world();
    let stranger = Device::new(&world, 0x31, 0);
    let exchange = stranger
        .call("procedure.listNotes", &json!({ "args": {} }))
        .send(&world)
        .await;
    assert_eq!(exchange.answer.status, StatusCode::UNAUTHORIZED);
    assert!(!exchange.answer.is_sealed());
    assert_eq!(error_message(&exchange.answer.body), UNAUTHENTICATED);
    assert!(world.built.devices.is_empty());
}

#[tokio::test]
async fn a_tampered_payload_is_401() {
    let world = world();
    let device = Device::new(&world, 0x32, 0);
    device.register(&world).await;
    let input = json!({ "args": { "text": "tamper-me-please" } });
    let payload = cbor(&input);
    let (sealed, request) = device.call("procedure.addNote", &input).seal().await;
    let mut bytes = sealed.bytes.to_vec();
    let at = bytes
        .windows(payload.len())
        .position(|window| window == payload.as_slice())
        .expect("the payload is a bstr inside the message");
    bytes[at + payload.len() - 1] ^= 0x01;
    let (parts, _) = request.into_parts();
    let tampered = Request::from_parts(parts, Body::from(bytes));
    let answer = send(&world.router, tampered).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    assert!(!answer.is_sealed());
    assert_eq!(error_message(&answer.body), UNAUTHENTICATED);
}

#[tokio::test]
async fn replayed_bytes_are_401() {
    let world = world();
    let device = Device::new(&world, 0x33, 0);
    device.register(&world).await;
    let (_, request) = device
        .call("procedure.addNote", &json!({ "args": { "text": "once" } }))
        .seal()
        .await;
    let (parts, body) = request.into_parts();
    let bytes = cratestack::axum::body::to_bytes(body, usize::MAX)
        .await
        .expect("body");
    let again = || Request::from_parts(parts.clone(), Body::from(bytes.clone()));
    assert_eq!(send(&world.router, again()).await.status, StatusCode::OK);
    let replay = send(&world.router, again()).await;
    assert_eq!(replay.status, StatusCode::UNAUTHORIZED);
    assert!(!replay.is_sealed());
    // The write ran once.
    let read = device
        .call("procedure.listNotes", &json!({ "args": {} }))
        .send(&world)
        .await;
    assert_eq!(
        read.open().await["notes"].as_array().expect("notes").len(),
        1
    );
}

#[tokio::test]
async fn a_stale_iat_is_401() {
    let world = world();
    // 301 s behind the server's clock; the allowed skew is 300 s.
    let late = Device::new(&world, 0x34, -301);
    late.register(&world).await;
    let exchange = late
        .call("procedure.listNotes", &json!({ "args": {} }))
        .send(&world)
        .await;
    assert_eq!(exchange.answer.status, StatusCode::UNAUTHORIZED);
    assert!(!exchange.answer.is_sealed());

    // And one inside the window is fine, so the test above is about the clock.
    let ok = Device::new(&world, 0x35, -250);
    ok.register(&world).await;
    let exchange = ok
        .call("procedure.listNotes", &json!({ "args": {} }))
        .send(&world)
        .await;
    assert_eq!(exchange.answer.status, StatusCode::OK);
}

#[tokio::test]
async fn plain_cbor_to_a_required_op_is_401() {
    let world = world();
    let device = Device::new(&world, 0x36, 0);
    device.register(&world).await;
    let answer = send(
        &world.router,
        plain("procedure.listNotes", &cbor(&json!({ "args": {} }))),
    )
    .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    assert!(!answer.is_sealed());
    assert_eq!(error_message(&answer.body), UNAUTHENTICATED);
}

#[tokio::test]
async fn cose_to_the_plain_op_is_415() {
    let world = world();
    let device = Device::new(&world, 0x37, 0);
    let (x, y) = device.xy();
    let exchange = device
        .call(
            "procedure.registerDevice",
            &json!({ "args": { "x": x, "y": y } }),
        )
        .send(&world)
        .await;
    assert_eq!(exchange.answer.status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    assert!(!exchange.answer.is_sealed());
    assert!(world.built.devices.is_empty(), "nothing was registered");
}

#[tokio::test]
async fn registering_something_that_is_not_a_key_is_refused() {
    let world = world();
    let payload = cbor(&json!({ "args": { "x": "AAAA", "y": "AAAA" } }));
    let answer = send(&world.router, plain("procedure.registerDevice", &payload)).await;
    assert!(answer.status.is_client_error(), "{}", answer.status);
    assert!(world.built.devices.is_empty());
}

fn frames(ops: &[(&str, Value)]) -> Value {
    Value::Array(
        ops.iter()
            .enumerate()
            .map(
                |(id, (op, input))| json!({ "id": id + 1, "op": op, "input": input, "idem": null }),
            )
            .collect(),
    )
}

async fn notes_of(world: &support::World, device: &Device) -> Value {
    let read = device
        .call("procedure.listNotes", &json!({ "args": {} }))
        .send(world)
        .await;
    assert_eq!(read.answer.status, StatusCode::OK);
    read.open().await["notes"].clone()
}

#[tokio::test]
async fn a_plain_batch_of_writes_is_401_and_writes_nothing() {
    let world = world();
    let device = Device::new(&world, 0x31, 0);
    device.register(&world).await;
    let body = cbor(&frames(&[(
        "procedure.addNote",
        json!({ "args": { "text": "sneaked" } }),
    )]));
    let answer = send(&world.router, plain("batch", &body)).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    assert!(!answer.is_sealed());
    assert_eq!(notes_of(&world, &device).await, json!([]));
}

#[tokio::test]
async fn a_plain_batch_of_only_the_registration_is_401_and_registers_nothing() {
    let world = world();
    let probe = Device::new(&world, 0x32, 0);
    let (x, y) = probe.xy();
    let body = cbor(&frames(&[(
        "procedure.registerDevice",
        json!({ "args": { "x": x, "y": y } }),
    )]));
    let answer = send(&world.router, plain("batch", &body)).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    assert!(!answer.is_sealed());
    assert!(
        world.built.devices.is_empty(),
        "the plain op must not be reachable through a batch"
    );
}

#[tokio::test]
async fn a_signed_batch_is_answered_sealed_and_runs_its_frames() {
    let world = world();
    let device = Device::new(&world, 0x33, 0);
    device.register(&world).await;
    let batch = device
        .call(
            "batch",
            &frames(&[(
                "procedure.addNote",
                json!({ "args": { "text": "in a batch" } }),
            )]),
        )
        .send(&world)
        .await;
    assert_eq!(
        batch.answer.status,
        StatusCode::OK,
        "{:?}",
        batch.answer.body
    );
    assert!(batch.answer.is_sealed());
    let answered = batch.open().await;
    assert_eq!(answered.as_array().map(Vec::len), Some(1), "{answered}");
    assert_eq!(
        notes_of(&world, &device).await.as_array().map(Vec::len),
        Some(1)
    );
}

#[tokio::test]
async fn a_retry_under_the_same_idempotency_key_is_one_note_and_is_sealed_for_the_retry() {
    let world = world();
    let device = Device::new(&world, 0x34, 0);
    device.register(&world).await;
    let write = || {
        device
            .call("procedure.addNote", &json!({ "args": { "text": "once" } }))
            .header("idempotency-key", "retry-1")
    };
    // Two messages (a fresh cti each), one payload, one key: the answer to the first is lost.
    let first = write().send(&world).await;
    let second = write().send(&world).await;
    assert_eq!(first.answer.status, StatusCode::OK);
    assert_eq!(second.answer.status, StatusCode::OK);
    assert_ne!(first.sealed.bytes, second.sealed.bytes);
    // The replayed answer is sealed for the second request (open() checks its digest).
    assert_eq!(second.open().await, first.open().await);
    assert_eq!(
        notes_of(&world, &device).await.as_array().map(Vec::len),
        Some(1)
    );

    // Another body under the same key is a conflict, not a second write.
    let other = device
        .call(
            "procedure.addNote",
            &json!({ "args": { "text": "different" } }),
        )
        .header("idempotency-key", "retry-1")
        .send(&world)
        .await;
    assert!(
        other.answer.status.is_client_error(),
        "{}",
        other.answer.status
    );
    assert_eq!(
        notes_of(&world, &device).await.as_array().map(Vec::len),
        Some(1)
    );
}

fn shared_key_write<'a>(device: &'a Device, text: &str) -> support::Call<'a> {
    device
        .call("procedure.addNote", &json!({ "args": { "text": text } }))
        .header("idempotency-key", "shared-key")
}

#[tokio::test]
async fn two_devices_using_one_idempotency_key_never_replay_each_other() {
    let world = world();
    let (alice, bob) = (Device::new(&world, 0x35, 0), Device::new(&world, 0x36, 0));
    alice.register(&world).await;
    bob.register(&world).await;
    let a = shared_key_write(&alice, "alice's").send(&world).await;
    let b = shared_key_write(&bob, "bob's").send(&world).await;
    assert_eq!(a.answer.status, StatusCode::OK);
    assert_eq!(b.answer.status, StatusCode::OK);
    assert_eq!(b.open().await["text"], "bob's");
    assert_eq!(
        notes_of(&world, &bob).await.as_array().map(Vec::len),
        Some(1)
    );
    assert_eq!(
        notes_of(&world, &alice).await.as_array().map(Vec::len),
        Some(1)
    );
}

#[tokio::test]
async fn unverified_callers_cannot_fill_the_idempotency_store() {
    let world = world();
    let device = Device::new(&world, 0x37, 0);
    device.register(&world).await;
    let (x, y) = device.xy();
    let body = cbor(&json!({ "args": { "x": x, "y": y } }));
    for i in 0..300 {
        let mut request = plain("procedure.registerDevice", &body);
        request.headers_mut().insert(
            "idempotency-key",
            format!("junk-{i}").parse().expect("value"),
        );
        request.headers_mut().insert(
            header::AUTHORIZATION,
            format!("Bearer junk-{i}").parse().expect("value"),
        );
        send(&world.router, request).await;
    }
    // The flood went through the unsigned op and was refused a key: nothing is held.
    assert_eq!(world.built.idempotency.len(), 0);
    let write = device
        .call(
            "procedure.addNote",
            &json!({ "args": { "text": "still works" } }),
        )
        .header("idempotency-key", "after-the-flood")
        .send(&world)
        .await;
    assert_eq!(write.answer.status, StatusCode::OK);
}

#[tokio::test]
async fn a_full_idempotency_store_is_a_sealed_503_never_a_refusal_the_client_drops() {
    let world = world();
    let device = Device::new(&world, 0x38, 0);
    device.register(&world).await;
    let mut last = None;
    for i in 0..220 {
        let write = device
            .call(
                "procedure.addNote",
                &json!({ "args": { "text": format!("n{i}") } }),
            )
            .header("idempotency-key", format!("k-{i}"))
            .send(&world)
            .await;
        last = Some((write.answer.status, write.answer.is_sealed()));
    }
    // Past the per-device cap the reservation fails before the handler: 503, sealed, so the
    // client keeps its queued write and moves to its next key.
    assert_eq!(last, Some((StatusCode::SERVICE_UNAVAILABLE, true)));
    assert_eq!(
        notes_of(&world, &device).await.as_array().map(Vec::len),
        Some(200)
    );
}

#[tokio::test]
async fn an_unmatched_method_is_not_a_signed_path() {
    let world = world();
    let request = Request::builder()
        .method(Method::GET)
        .uri("/rpc/procedure.listNotes")
        .header(header::ACCEPT, SIGN1)
        .body(Body::empty())
        .expect("request");
    let answer = send(&world.router, request).await;
    assert!(answer.status.is_client_error(), "{}", answer.status);
    assert!(!answer.is_sealed());
}
