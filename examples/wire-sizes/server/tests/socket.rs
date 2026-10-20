//! One request over a real socket, to pin what the in-process measurement leaves out.
//!
//! The runner never opens a socket (`runner.rs` drives the router with `oneshot`), so the numbers
//! in `REPORT.md` are the HTTP message as the handler stack sees it. This test sends the same
//! request over TCP to the same router, served by `axum::serve` (hyper), and compares three things:
//!
//! - what the server's [`Exchange`] says the request weighed with the bytes written to the socket.
//!   They are equal, so the rebuilt request line is exact;
//! - the request in process with the request on the socket. The stack gets two more headers,
//!   `host` and `content-length`, which the test adds as any HTTP/1.1 client does;
//! - the response the stack produced with the bytes read back. Hyper adds `content-length` and
//!   `date` and nothing else, and the status line is the one [`Exchange::status_line`] rebuilds.
//!
//! The README's "Where the measurement is taken" rests on this. The request is built by
//! `runner::request_for`, so it carries exactly the headers the runner sends. It is sent for the
//! one plain call of every variant (`registerDevice`) and for `listNotes` in the two plain
//! variants. A sealed call is not sent over the socket, because it needs the device key, which the
//! runner keeps to itself.

#![allow(clippy::expect_used, reason = "tests may expect")]

use std::collections::BTreeSet;
use std::io::{Read as _, Write as _};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use cratestack::axum::body::{Body, to_bytes};
use cratestack::axum::http::Request;
use cratestack::serde_json::{Value, json};
use tower::ServiceExt as _;
use wire_sizes_demo_server::measure::Exchange;
use wire_sizes_demo_server::report::BEARER_BASELINE;
use wire_sizes_demo_server::runner;
use wire_sizes_demo_server::{DEFAULT_AUDIENCE, REGISTER_OP, Variant, build, random_scalar};

const LIST_OP: &str = "procedure.listNotes";

/// A call, as the runner would make it.
struct Call {
    variant: Variant,
    op: &'static str,
    args: Value,
}

impl Call {
    fn register(variant: Variant) -> Self {
        let (x, y) = runner::placeholder_xy().expect("a key-shaped pair");
        Self {
            variant,
            op: REGISTER_OP,
            args: json!({ "args": { "x": x, "y": y } }),
        }
    }

    fn list(variant: Variant) -> Self {
        Self {
            variant,
            op: LIST_OP,
            args: json!({ "args": {} }),
        }
    }

    /// The plain variants carry a `Bearer` header; the `cose` server has none to send.
    fn bearer(&self) -> Option<&'static str> {
        match self.variant {
            Variant::Json | Variant::Cbor => Some(BEARER_BASELINE),
            Variant::Cose => None,
        }
    }
}

/// One call, sent in process and over a socket.
struct Observed {
    /// The bytes written to the socket.
    written: Vec<u8>,
    /// The bytes read back: the whole response.
    read: Vec<u8>,
    /// The address the request was sent to, for the `host` header.
    addr: SocketAddr,
    /// What the measuring layer recorded for the request that came over the socket.
    socket: Exchange,
    /// What it recorded for the same request sent in process.
    in_process: Exchange,
}

/// The size of one header line: `name: value\r\n`.
fn line(name: &str, value: &str) -> usize {
    name.len() + ": ".len() + value.len() + "\r\n".len()
}

fn names(headers: &[(String, String)]) -> BTreeSet<String> {
    headers.iter().map(|(name, _)| name.clone()).collect()
}

fn set(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

/// A byte count as a signed number, so a difference can be negative.
fn signed(n: usize) -> i64 {
    i64::try_from(n).expect("a small count")
}

/// How many digits `n` has in decimal, which is what `content-length` spends on it.
fn digits(n: usize) -> usize {
    n.to_string().len()
}

/// A request as HTTP/1.1 text: the request the runner builds, plus the `host` and `content-length`
/// a client puts on the wire.
async fn http1(request: Request<Body>, addr: SocketAddr) -> Vec<u8> {
    let (parts, body) = request.into_parts();
    let body = to_bytes(body, usize::MAX).await.expect("a body");
    let mut out = format!("{} {} HTTP/1.1\r\n", parts.method, parts.uri.path()).into_bytes();
    for (name, value) in &parts.headers {
        out.extend_from_slice(name.as_str().as_bytes());
        out.extend_from_slice(b": ");
        out.extend_from_slice(value.as_bytes());
        out.extend_from_slice(b"\r\n");
    }
    out.extend_from_slice(format!("host: {addr}\r\n").as_bytes());
    out.extend_from_slice(format!("content-length: {}\r\n\r\n", body.len()).as_bytes());
    out.extend_from_slice(&body);
    out
}

/// Writes `request` to `addr` and reads one whole response.
///
/// The response is read by its `content-length`, not to the end of the connection, so the request
/// needs no `connection: close` and the exchange is the one a keep-alive client would have. Hyper
/// sizes every response of this server, so there is always a `content-length` to read by.
fn round_trip(addr: SocketAddr, request: &[u8]) -> Vec<u8> {
    let mut stream = TcpStream::connect(addr).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("a read timeout");
    stream.write_all(request).expect("write");

    let mut read = Vec::new();
    let mut chunk = [0_u8; 8192];
    let mut more = |read: &mut Vec<u8>| {
        let n = stream.read(&mut chunk).expect("read");
        assert!(n > 0, "the server closed the connection early");
        read.extend_from_slice(&chunk[..n]);
    };
    let head_len = loop {
        if let Some(i) = read.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        more(&mut read);
    };
    let head = head_of(&read);
    let body_len: usize = head
        .headers
        .iter()
        .find(|(name, _)| name == "content-length")
        .expect("hyper sizes the response")
        .1
        .parse()
        .expect("a number");
    while read.len() < head_len + body_len {
        more(&mut read);
    }
    read
}

/// A response head, parsed.
struct Head {
    status_line: String,
    headers: Vec<(String, String)>,
    /// The head's size, including the blank line that ends it.
    len: usize,
}

fn head_of(read: &[u8]) -> Head {
    let end = read
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .expect("a response head");
    let text = std::str::from_utf8(&read[..end]).expect("a text head");
    let mut lines = text.split("\r\n");
    let status_line = lines.next().expect("a status line").to_owned();
    let headers = lines
        .map(|l| {
            let (name, value) = l.split_once(": ").expect("`name: value`");
            (name.to_owned(), value.to_owned())
        })
        .collect();
    Head {
        status_line,
        headers,
        len: end + 4,
    }
}

/// Sends `call` in process, and again over a socket to a fresh server of the same variant.
async fn observe(call: &Call) -> Observed {
    let scalar = random_scalar().expect("a scalar");
    let body = runner::encode(call.variant, &call.args).expect("an encoded body");
    let request = || {
        runner::request_for(call.variant, call.op, body.clone(), call.bearer()).expect("a request")
    };

    let built = build(call.variant, DEFAULT_AUDIENCE, &scalar).expect("a server");
    let response = built
        .router
        .clone()
        .oneshot(request())
        .await
        .expect("a response");
    to_bytes(response.into_body(), usize::MAX)
        .await
        .expect("a body");
    let in_process = built.exchanges.exchanges().remove(0);

    let built = build(call.variant, DEFAULT_AUDIENCE, &scalar).expect("a server");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("a free port");
    let addr = listener.local_addr().expect("an address");
    let router = built.router.clone();
    let server = tokio::spawn(async move { cratestack::axum::serve(listener, router).await });
    let written = http1(request(), addr).await;
    let read = tokio::task::spawn_blocking({
        let written = written.clone();
        move || round_trip(addr, &written)
    })
    .await
    .expect("the socket thread");
    server.abort();
    let socket = built.exchanges.exchanges().remove(0);

    Observed {
        written,
        read,
        addr,
        socket,
        in_process,
    }
}

impl Observed {
    /// What a socket adds to the request, in bytes: the socket's count less the in-process one.
    fn request_added(&self) -> usize {
        self.socket.request_total_bytes() - self.in_process.request_total_bytes()
    }

    /// What hyper adds to the response, in bytes: the bytes read less the exchange's count.
    fn response_added(&self) -> usize {
        self.read.len() - self.socket.response_total_bytes()
    }
}

#[tokio::test]
async fn a_socket_adds_host_and_content_length_to_the_request() {
    let calls = [
        Call::register(Variant::Json),
        Call::register(Variant::Cbor),
        Call::register(Variant::Cose),
        Call::list(Variant::Json),
        Call::list(Variant::Cbor),
    ];
    for call in &calls {
        let seen = observe(call).await;
        let what = format!("{:?} {}", call.variant, call.op);

        // The exchange's count is the number of bytes written: the rebuilt request line is exact.
        assert_eq!(
            seen.socket.request_total_bytes(),
            seen.written.len(),
            "{what}: the exchange weighs what the socket carried"
        );
        assert_eq!(seen.socket.status, 200, "{what}");
        assert_eq!(seen.in_process.status, 200, "{what}");

        // The stack gets `host` and `content-length` over a socket and nothing else, and loses
        // nothing the runner sends.
        let socket_names = names(&seen.socket.request_headers);
        let process_names = names(&seen.in_process.request_headers);
        assert!(process_names.is_subset(&socket_names), "{what}");
        assert_eq!(
            socket_names
                .difference(&process_names)
                .cloned()
                .collect::<BTreeSet<_>>(),
            set(&["content-length", "host"]),
            "{what}: the request headers a socket adds"
        );
        let content_length = seen.socket.request_body_bytes.to_string();
        assert_eq!(
            seen.request_added(),
            line("host", &seen.addr.to_string()) + line("content-length", &content_length),
            "{what}: the request bytes a socket adds"
        );
        assert_eq!(
            seen.in_process.request_body_bytes, seen.socket.request_body_bytes,
            "{what}: the body is the same"
        );
    }
}

#[tokio::test]
async fn hyper_adds_content_length_and_date_to_the_response() {
    let calls = [
        Call::register(Variant::Json),
        Call::register(Variant::Cbor),
        Call::register(Variant::Cose),
        Call::list(Variant::Json),
        Call::list(Variant::Cbor),
    ];
    for call in &calls {
        let seen = observe(call).await;
        let what = format!("{:?} {}", call.variant, call.op);
        let head = head_of(&seen.read);

        // The status line is the one the exchange rebuilds.
        assert_eq!(head.status_line, seen.socket.status_line(), "{what}");

        // Every header the stack set is on the socket, and what else is there is hyper's.
        assert!(
            seen.socket
                .response_headers
                .iter()
                .all(|header| head.headers.contains(header)),
            "{what}: the stack's headers reach the socket"
        );
        let added: Vec<&(String, String)> = head
            .headers
            .iter()
            .filter(|header| !seen.socket.response_headers.contains(header))
            .collect();
        assert_eq!(
            added
                .iter()
                .map(|(name, _)| name.clone())
                .collect::<BTreeSet<_>>(),
            set(&["content-length", "date"]),
            "{what}: the response headers hyper adds"
        );

        // The lines hyper adds are the whole difference between the exchange and the socket.
        let added_bytes: usize = added.iter().map(|(name, value)| line(name, value)).sum();
        assert_eq!(seen.response_added(), added_bytes, "{what}");
        assert_eq!(
            seen.read.len() - head.len,
            seen.socket.response_body_bytes,
            "{what}: the body is the same"
        );
        let content_length = seen.socket.response_body_bytes.to_string();
        let date = added
            .iter()
            .find(|(name, _)| name == "date")
            .expect("a date header");
        // An HTTP date is always 29 bytes (`Mon, 19 Oct 2026 19:22:25 GMT`), so the line is 37.
        assert_eq!(line("date", &date.1), 37, "{what}");
        assert_eq!(
            seen.response_added(),
            line("content-length", &content_length) + 37,
            "{what}: the response bytes a socket adds"
        );

        // The stack sets the same headers in process, so the exchange is the same either way.
        assert_eq!(
            seen.in_process.response_headers, seen.socket.response_headers,
            "{what}"
        );
        assert_eq!(
            seen.in_process.response_body_bytes, seen.socket.response_body_bytes,
            "{what}"
        );
    }
}

#[tokio::test]
async fn a_difference_between_variants_holds_to_within_the_content_length_digits() {
    // JSON against CBOR for the same call, in process and over a socket. The two differ by the
    // digits of `content-length` and by nothing else: `listNotes` has an 11-byte body in JSON and a
    // 7-byte one in CBOR, so the socket makes JSON's request one byte larger against CBOR's than
    // the in-process count says, and the response likewise.
    for (json, cbor) in [
        (Call::register(Variant::Json), Call::register(Variant::Cbor)),
        (Call::list(Variant::Json), Call::list(Variant::Cbor)),
    ] {
        let (json, cbor) = (observe(&json).await, observe(&cbor).await);
        let what = json.socket.path.clone();

        let in_process = signed(json.in_process.request_total_bytes())
            - signed(cbor.in_process.request_total_bytes());
        let socket =
            signed(json.socket.request_total_bytes()) - signed(cbor.socket.request_total_bytes());
        assert_eq!(
            socket - in_process,
            signed(digits(json.socket.request_body_bytes))
                - signed(digits(cbor.socket.request_body_bytes)),
            "{what}: the request difference moves by the digits of content-length"
        );

        let in_process = signed(json.in_process.response_total_bytes())
            - signed(cbor.in_process.response_total_bytes());
        let socket = signed(json.read.len()) - signed(cbor.read.len());
        assert_eq!(
            socket - in_process,
            signed(digits(json.socket.response_body_bytes))
                - signed(digits(cbor.socket.response_body_bytes)),
            "{what}: the response difference moves by the digits of content-length"
        );
    }
}
