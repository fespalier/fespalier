//! The core against the example's own server, in process (plan section 12). The server is
//! `frb_cose_demo_server::build`, served by `cratestack_server::axum::serve` on a loopback port; the core is the one
//! the app loads, with a device that signs for real (the server checks every signature) or a callback that refuses.
//!
//! Each server runs on a thread with a runtime of its own. Dropping it drops that runtime, which closes its listener
//! and every connection, as a killed process would. A task on the test's runtime would keep a pooled connection
//! alive, and the core would keep talking to the old registry.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use std::net::{Ipv4Addr, SocketAddr, TcpListener};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

use cratestack::cose::{CoseSigner, P256Signer};
use cratestack_server::axum;
use frb_cose_core::core::journal::{Entry, Outcome};
use frb_cose_core::core::signer::{SignFn, SignFuture};
use frb_cose_core::core::{Config, Core, Error, Event, identity};
use frb_cose_demo_server::idempotency::MemoryIdempotency;
use frb_cose_demo_server::registry::DeviceKeys;
use frb_cose_demo_server::{Built, build};
use serde_json::{Value, json};

const AUDIENCE: &str = "fespalier-frb-cose";
/// The server's response key. Fixed, so a failing run can be reproduced.
const SERVER_SCALAR: [u8; 32] = [7; 32];

fn loopback() -> SocketAddr {
    SocketAddr::new(Ipv4Addr::LOCALHOST.into(), 0)
}

/// A running server. Dropping it stops it.
struct Server {
    addr: SocketAddr,
    devices: DeviceKeys,
    idempotency: Arc<MemoryIdempotency>,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<thread::JoinHandle<()>>,
}

impl Server {
    /// Starts the server on `addr` (port 0 picks a free one). A restart on the same address keeps the core's URL.
    fn start(addr: SocketAddr) -> Self {
        let Built {
            router,
            devices,
            idempotency,
            ..
        } = build(AUDIENCE, &SERVER_SCALAR).expect("the server");
        let (stop, stop_rx) = tokio::sync::oneshot::channel();
        let (bound, bound_rx) = std::sync::mpsc::channel::<SocketAddr>();
        let thread = thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("a runtime");
            runtime.block_on(async move {
                let listener = tokio::net::TcpListener::bind(addr)
                    .await
                    .expect("a listener");
                bound
                    .send(listener.local_addr().expect("an address"))
                    .expect("the test waits");
                tokio::select! {
                    served = axum::serve(listener, router.into_make_service()) => {
                        served.expect("the server runs");
                    }
                    _ = stop_rx => {}
                }
            });
        });
        let addr = bound_rx.recv().expect("the server is listening");
        Self {
            addr,
            devices,
            idempotency,
            stop: Some(stop),
            thread: Some(thread),
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The server's public point, x and y: what a core pins.
fn server_point() -> (Vec<u8>, Vec<u8>) {
    let sec1 = P256Signer::from_scalar(&SERVER_SCALAR)
        .expect("a scalar")
        .verify_key()
        .p256_sec1_uncompressed()
        .expect("P-256");
    (sec1[1..33].to_vec(), sec1[33..].to_vec())
}

/// A device: a P-256 key, whose public point the core is given.
struct Device {
    signer: Arc<P256Signer>,
    x: Vec<u8>,
    y: Vec<u8>,
}

impl Device {
    fn new(seed: u8) -> Self {
        let signer = P256Signer::from_scalar(&[seed; 32]).expect("a scalar");
        let sec1 = signer.verify_key().p256_sec1_uncompressed().expect("P-256");
        Self {
            x: sec1[1..33].to_vec(),
            y: sec1[33..].to_vec(),
            signer: Arc::new(signer),
        }
    }

    /// The device's key signs for real: the server verifies the signature.
    fn signing(&self) -> SignFn {
        let signer = Arc::clone(&self.signer);
        Arc::new(move |to_be_signed: Vec<u8>| -> SignFuture {
            let signer = Arc::clone(&signer);
            Box::pin(async move { signer.sign(&to_be_signed).await.ok() })
        })
    }
}

/// A callback that answers that the key did not sign.
fn refusing() -> SignFn {
    Arc::new(|_: Vec<u8>| -> SignFuture { Box::pin(async { None }) })
}

/// A callback that never answers: only the core's timeout ends the wait.
fn never_answers() -> SignFn {
    Arc::new(|_: Vec<u8>| -> SignFuture { Box::pin(std::future::pending()) })
}

/// Counts the callback's calls, then answers as `sign` does.
fn counting(sign: SignFn, counter: Arc<AtomicUsize>) -> SignFn {
    Arc::new(move |to_be_signed: Vec<u8>| {
        counter.fetch_add(1, Ordering::SeqCst);
        sign(to_be_signed)
    })
}

fn config(addr: SocketAddr, device: &Device, (server_x, server_y): (Vec<u8>, Vec<u8>)) -> Config {
    Config {
        base_url: format!("http://{addr}"),
        audience: AUDIENCE.to_owned(),
        device_x: device.x.clone(),
        device_y: device.y.clone(),
        server_x,
        server_y,
    }
}

fn open(addr: SocketAddr, device: &Device, sign: SignFn) -> Core {
    Core::open(config(addr, device, server_point()), sign).expect("the core opens")
}

fn body(answer: &frb_cose_core::core::Answer) -> Value {
    serde_json::from_str(&answer.body_json).expect("the body is JSON")
}

fn last_row(core: &Core) -> Entry {
    core.journal().last().cloned().expect("a journal row")
}

fn count(core: &Core, wanted: &Event) -> usize {
    core.subscribe()
        .0
        .iter()
        .filter(|event| *event == wanted)
        .count()
}

#[tokio::test]
async fn registration_happens_once_and_the_call_is_sealed_and_opens() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let core = open(server.addr, &device, device.signing());

    let answer = core
        .call("addNote", r#"{"text":"hi"}"#, "k#0")
        .await
        .expect("the write is answered");
    assert_eq!(answer.status, 200);
    assert_eq!(body(&answer), json!({"id": 1, "text": "hi"}));
    assert_eq!(server.devices.len(), 1, "the device was registered");

    let list = core
        .call("listNotes", "{}", "")
        .await
        .expect("the read is answered");
    assert_eq!(body(&list), json!({"notes": [{"id": 1, "text": "hi"}]}));

    assert_eq!(
        count(&core, &Event::Registered),
        1,
        "one registration for two calls"
    );
    let status = core.status();
    assert!(status.registered);
    assert_eq!(
        status.kid,
        identity(&device.x, &device.y).expect("the identity").kid
    );
}

#[tokio::test]
async fn the_same_key_replays_the_same_answer_and_runs_the_write_once() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let core = open(server.addr, &device, device.signing());

    let first = core
        .call("addNote", r#"{"text":"once"}"#, "k#1")
        .await
        .expect("answered");
    let again = core
        .call("addNote", r#"{"text":"once"}"#, "k#1")
        .await
        .expect("answered");
    assert_eq!(first, again);

    let list = core.call("listNotes", "{}", "").await.expect("answered");
    assert_eq!(
        body(&list)["notes"].as_array().map(Vec::len),
        Some(1),
        "the retry did not run the write again"
    );
}

#[tokio::test]
async fn a_restarted_server_forgets_the_key_and_the_next_call_registers_again() {
    let server = Server::start(loopback());
    let addr = server.addr;
    let device = Device::new(1);
    let core = open(addr, &device, device.signing());
    core.call("addNote", r#"{"text":"before"}"#, "k#0")
        .await
        .expect("answered");

    drop(server);
    let restarted = Server::start(addr);
    assert!(
        restarted.devices.is_empty(),
        "a restart has an empty registry"
    );

    // The core's pooled connection to the old server is dead. The request that meets it may fail as a transport
    // failure (it went out on a closed socket, and a sealed request is never replayed by the client). The next one
    // opens a new connection, which reaches the restarted server: the server refuses the key.
    let refused = match core.call("listNotes", "{}", "").await {
        Err(Error::Transport(_)) => core.call("listNotes", "{}", "").await,
        answered => answered,
    }
    .expect_err("the restarted server does not know the key");
    assert_eq!(refused, Error::Unsigned { status: 401 });
    assert!(core.subscribe().0.contains(&Event::Forgotten));
    assert!(!core.status().registered);

    core.call("listNotes", "{}", "")
        .await
        .expect("the next call registers and is answered");
    assert_eq!(restarted.devices.len(), 1);
    assert_eq!(count(&core, &Event::Registered), 2, "registered again");
}

#[tokio::test]
async fn a_core_pinned_to_another_key_refuses_the_answer_and_the_write_still_landed() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let other = P256Signer::from_scalar(&[9; 32]).expect("a scalar");
    let other = other.verify_key().p256_sec1_uncompressed().expect("P-256");
    let pinned_elsewhere = (other[1..33].to_vec(), other[33..].to_vec());
    let core = Core::open(
        config(server.addr, &device, pinned_elsewhere),
        device.signing(),
    )
    .expect("the core opens");

    let error = core
        .call("addNote", r#"{"text":"pinned"}"#, "k#2")
        .await
        .expect_err("the answer is sealed by a key this core does not pin");
    assert_eq!(error, Error::Unverified);
    let row = last_row(&core);
    assert_eq!((row.outcome, row.sent), (Outcome::Unverified, true));

    let checker = open(server.addr, &device, device.signing());
    let list = checker.call("listNotes", "{}", "").await.expect("answered");
    assert_eq!(
        body(&list)["notes"][0]["text"],
        "pinned",
        "the write landed though its answer was refused"
    );
}

#[tokio::test]
async fn a_signer_that_answers_null_seals_nothing() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let core = open(server.addr, &device, refusing());

    let error = core
        .call("addNote", r#"{"text":"x"}"#, "k#3")
        .await
        .expect_err("no signature");
    assert!(matches!(error, Error::Seal(_)), "{error:?}");
    assert!(server.idempotency.is_empty(), "no write reached the server");
    let row = last_row(&core);
    assert_eq!((row.outcome, row.sent), (Outcome::NotSigned, false));
}

#[tokio::test]
async fn a_signer_that_does_not_answer_in_time_seals_nothing() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let core = Core::open_with_timeout(
        config(server.addr, &device, server_point()),
        never_answers(),
        Duration::from_millis(50),
    )
    .expect("the core opens");

    let error = core
        .call("addNote", r#"{"text":"x"}"#, "k#3")
        .await
        .expect_err("the timeout");
    assert!(matches!(error, Error::Seal(_)), "{error:?}");
    assert!(server.idempotency.is_empty(), "no write reached the server");
    let row = last_row(&core);
    assert_eq!((row.outcome, row.sent), (Outcome::NotSigned, false));
}

#[tokio::test]
async fn a_bad_op_or_bad_arguments_are_refused_before_anything_is_attempted() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let signed = Arc::new(AtomicUsize::new(0));
    let core = open(
        server.addr,
        &device,
        counting(device.signing(), Arc::clone(&signed)),
    );

    let refused = [
        // The registration is the core's own, plain: it is not an op a caller can make.
        ("registerDevice", "{}", "k#4"),
        ("noSuchOp", "{}", "k#4"),
        ("addNote", r#"{"text":5}"#, "k#4"),
        // A write without a key, and a key that is not a header value.
        ("addNote", r#"{"text":"x"}"#, ""),
        ("addNote", r#"{"text":"x"}"#, "has a space"),
        // A read sends no key.
        ("listNotes", "{}", "k#4"),
        ("listNotes", r#"{"limit":"x"}"#, ""),
    ];
    for (op, args, key) in refused {
        let error = core.call(op, args, key).await.expect_err(op);
        assert!(matches!(error, Error::BadInput(_)), "{op}: {error:?}");
    }
    assert_eq!(signed.load(Ordering::SeqCst), 0, "nothing was signed");
    assert!(server.devices.is_empty(), "nothing was registered");
    assert!(core.journal().is_empty(), "a refused call has no row");
}

#[tokio::test]
async fn the_journal_is_bounded_and_holds_no_payload() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let core = open(server.addr, &device, device.signing());

    for _ in 0..frb_cose_core::core::journal::CAPACITY + 5 {
        core.call("listNotes", "{}", "").await.expect("answered");
    }
    assert_eq!(core.journal().len(), frb_cose_core::core::journal::CAPACITY);

    core.call("addNote", r#"{"text":"SECRET-PAYLOAD"}"#, "k#5")
        .await
        .expect("answered");
    let rows = core.journal();
    assert_eq!(rows.len(), frb_cose_core::core::journal::CAPACITY);
    let last = rows.last().expect("a row");
    assert_eq!(last.op, "addNote");
    assert_eq!(last.idempotency_key, "k#5");
    assert_eq!(
        (last.outcome, last.status, last.sent),
        (Outcome::Answered, Some(200), true)
    );
    assert!(
        !format!("{rows:?}").contains("SECRET-PAYLOAD"),
        "no row holds the arguments"
    );
}

#[tokio::test]
async fn a_sealed_refusal_is_an_answer_that_carries_its_wire_code() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let core = open(server.addr, &device, device.signing());
    core.call("addNote", r#"{"text":"first"}"#, "k#6")
        .await
        .expect("answered");

    // The same key with another body is refused by the server, and the refusal is sealed.
    let refusal = core
        .call("addNote", r#"{"text":"other"}"#, "k#6")
        .await
        .expect("the refusal is an answer, not an error");
    // The server's status for a reused key is 422 (its `invalid_argument`), not 400: the code is what the app reads.
    assert_eq!(refusal.status, 422, "{}", refusal.body_json);
    assert_eq!(body(&refusal)["code"], "invalid_argument");
    assert_eq!(last_row(&core).outcome, Outcome::Answered);
}

#[tokio::test]
async fn a_server_that_is_gone_is_a_transport_failure_named_by_its_class() {
    let server = Server::start(loopback());
    let device = Device::new(1);
    let core = open(server.addr, &device, device.signing());
    core.call("addNote", r#"{"text":"up"}"#, "k#7")
        .await
        .expect("answered");
    drop(server);

    let error = core
        .call("listNotes", "{}", "")
        .await
        .expect_err("nothing listens");
    let Error::Transport(text) = error else {
        panic!("a transport failure, got {error:?}");
    };
    assert!(
        [
            "the server could not be reached",
            "the server did not answer",
            "the server did not answer in time"
        ]
        .contains(&text),
        "{text}"
    );
    // Only a connection that was never made is known to have sent nothing; a dead pooled connection or a timeout
    // may have carried the request, and the row says so.
    let row = last_row(&core);
    assert_eq!(
        (row.outcome, row.sent),
        (
            Outcome::Unreachable,
            text != "the server could not be reached"
        )
    );
}

#[tokio::test]
async fn a_registration_that_cannot_reach_the_server_says_so_with_no_client_text() {
    // Bind and drop: the port is free, so nothing listens on it.
    let addr = TcpListener::bind(loopback())
        .expect("a port")
        .local_addr()
        .expect("an address");
    let device = Device::new(1);
    let core = open(addr, &device, device.signing());

    let error = core
        .call("listNotes", "{}", "")
        .await
        .expect_err("nothing listens");
    assert_eq!(
        error,
        Error::Registration("the server did not answer the registration")
    );
    assert!(!error.to_string().contains("127.0.0.1"));
    let row = last_row(&core);
    assert_eq!((row.outcome, row.sent), (Outcome::NotRegistered, false));
}
