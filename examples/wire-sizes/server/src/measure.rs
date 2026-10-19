//! What a request and its response weighed, as the handler stack saw them.
//!
//! [`measure`] is a middleware that wraps the whole router. It records each request as the router
//! received it and each response as the router produced it, before hyper writes either to a
//! connection. A count is therefore the size of **the HTTP message the handler stack handled**,
//! not the number of bytes on a socket:
//!
//! - A request counts its request line (rebuilt from the method and the path, because no
//!   middleware sees it), every header the router received, and the body. A real HTTP/1.1 request
//!   also carries `host` and `content-length`, and whatever its client adds (`user-agent`,
//!   `accept-encoding`, ...). They are counted only if the sender put them in the request; the
//!   runner does not, because it builds the request itself and never opens a socket.
//! - A response counts its status line (rebuilt from the status), every header the stack set, and
//!   the body. A real response also carries what hyper adds when it writes it: for this server
//!   `content-length` (the stack sets none) and `date`.
//! - TCP and TLS framing is not counted.
//!
//! Those additions are the same for every variant except the digits of `content-length`, so a
//! difference between two variants holds to within that, and a total is a lower bound.
//! `tests/socket.rs` sends a request over a real socket and pins what the additions are.
//!
//! Nothing here parses the payload: the bytes are counted as they were received, so a malformed
//! body is still weighed, and the measurement does not change what the server answers.

use std::sync::{Arc, Mutex, PoisonError};

use cratestack::axum::body::{Body, HttpBody as _, to_bytes};
use cratestack::axum::extract::Request;
use cratestack::axum::http::{HeaderMap, HeaderName, StatusCode};
use cratestack::axum::middleware::Next;
use cratestack::axum::response::{IntoResponse, Response};

/// One measured exchange: what arrived, and what was sent back.
#[derive(Clone, Debug)]
pub struct Exchange {
    /// The HTTP method.
    pub method: String,
    /// The path, e.g. `/rpc/procedure.listNotes`.
    pub path: String,
    /// Every header that arrived, name and value, exactly as received (lowercased names).
    pub request_headers: Vec<(String, String)>,
    /// The exact number of body bytes that arrived.
    pub request_body_bytes: usize,
    /// The status the server answered.
    pub status: u16,
    /// Every header the server sent.
    pub response_headers: Vec<(String, String)>,
    /// The exact number of body bytes the server sent.
    pub response_body_bytes: usize,
}

impl Exchange {
    /// The request line as text, without its line ending: `<METHOD> <path> HTTP/1.1`.
    ///
    /// A middleware never sees the request line, so it is rebuilt from the method and the path. The
    /// query string is not part of `path`, so a request that has one is counted short by its length;
    /// none of the scenario's calls has one.
    #[must_use]
    pub fn request_line(&self) -> String {
        format!("{} {} HTTP/1.1", self.method, self.path)
    }

    /// The size of the request line with its line ending: `<METHOD> <path> HTTP/1.1\r\n`.
    ///
    /// It is part of every request, and for one op it is the same in every variant.
    #[must_use]
    pub fn request_line_bytes(&self) -> usize {
        self.request_line().len() + "\r\n".len()
    }

    /// The status line as text, without its line ending: `HTTP/1.1 <status> <reason>`.
    ///
    /// A middleware never sees the status line either. The reason is the status's canonical phrase,
    /// which is what hyper writes; for a status that has none hyper writes `<none>` (hyper 1.12,
    /// `proto/h1/role.rs`, the server's `encode`), and so does this.
    #[must_use]
    pub fn status_line(&self) -> String {
        let reason = StatusCode::from_u16(self.status)
            .ok()
            .and_then(|status| status.canonical_reason())
            .unwrap_or("<none>");
        format!("HTTP/1.1 {} {reason}", self.status)
    }

    /// The size of the status line with its line ending: `HTTP/1.1 <status> <reason>\r\n`.
    #[must_use]
    pub fn status_line_bytes(&self) -> usize {
        self.status_line().len() + "\r\n".len()
    }

    /// Every request byte except the body: the request line plus the header block, each header as
    /// `name: value\r\n`, closed by a blank line.
    #[must_use]
    pub fn request_head_bytes(&self) -> usize {
        self.request_line_bytes()
            + self
                .request_headers
                .iter()
                .map(|(n, v)| n.len() + ": ".len() + v.len() + 2)
                .sum::<usize>()
            + 2
    }

    /// Every response byte except the body.
    #[must_use]
    pub fn response_head_bytes(&self) -> usize {
        self.status_line_bytes()
            + self
                .response_headers
                .iter()
                .map(|(n, v)| n.len() + ": ".len() + v.len() + 2)
                .sum::<usize>()
            + 2
    }

    /// Every request byte: head plus body.
    #[must_use]
    pub fn request_total_bytes(&self) -> usize {
        self.request_head_bytes() + self.request_body_bytes
    }

    /// Every response byte: head plus body.
    #[must_use]
    pub fn response_total_bytes(&self) -> usize {
        self.response_head_bytes() + self.response_body_bytes
    }

    /// The name of the header carrying the payload's media type, if it arrived.
    #[must_use]
    pub fn content_type(&self) -> Option<&str> {
        self.request_headers
            .iter()
            .find(|(n, _)| n == "content-type")
            .map(|(_, v)| v.as_str())
    }

    /// Whether the request carried an `Authorization` header.
    ///
    /// This is the point of the comparison: a COSE-signed call puts its credential in the body,
    /// so it has none, while the bearer baseline puts one here.
    #[must_use]
    pub fn has_authorization(&self) -> bool {
        self.request_headers
            .iter()
            .any(|(n, _)| n == "authorization")
    }

    /// The size of the `Authorization` header's value, or 0 when there is none.
    #[must_use]
    pub fn authorization_bytes(&self) -> usize {
        self.request_headers
            .iter()
            .find(|(n, _)| n == "authorization")
            .map_or(0, |(n, v)| n.len() + ": ".len() + v.len() + 2)
    }
}

/// The exchanges this server has measured, oldest first.
#[derive(Clone, Default)]
pub struct ExchangeLog(Arc<Mutex<Vec<Exchange>>>);

impl ExchangeLog {
    /// An empty log.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Every exchange measured so far.
    ///
    /// A poisoned lock yields the records taken before the panic rather than nothing: a
    /// measurement run that lost its numbers to an unrelated panic would be worse than useless.
    #[must_use]
    pub fn exchanges(&self) -> Vec<Exchange> {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// How many exchanges have been measured.
    #[must_use]
    pub fn len(&self) -> usize {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Whether nothing has been measured.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Forgets every exchange.
    pub fn clear(&self) {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
    }

    fn record(&self, exchange: Exchange) {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(exchange);
    }
}

/// How much of a body is read and weighed.
///
/// **It must not be smaller than the body limit the router accepts.** The layer hands the router
/// the bytes it kept, so a limit below the router's would truncate a large body and the codec would
/// refuse it with a `400` the client did not cause (an earlier version set this to 1 MiB against
/// the router's 2 MiB, [`cratestack::DEFAULT_BODY_LIMIT_BYTES`]). It is the router's limit plus
/// 4 MiB, so every body the router accepts is passed on whole. A body over the router's limit is
/// refused by the router, and this layer counts the bytes that arrived, up to its own limit.
pub const MEASURE_LIMIT_BYTES: usize = cratestack::DEFAULT_BODY_LIMIT_BYTES + (4 * 1024 * 1024);

/// Measures every request and response, and records them in `log`.
///
/// Outermost in the stack: a refusal from any inner layer (the envelope layer's `401`, the codec's
/// `400`) is an exchange with a size, and it is recorded like any other.
pub async fn measure(log: ExchangeLog, request: Request, next: Next) -> Response {
    let method = request.method().to_string();
    let path = request.uri().path().to_owned();
    let request_headers = headers_of(request.headers());

    // Read the body ourselves so its exact byte count is known, then hand the same bytes on: the
    // layers below must see a body identical to what arrived, or the measurement would change
    // the behaviour it is measuring.
    let (parts, mut body) = request.into_parts();
    let mut kept = Vec::new();
    let mut seen = 0_usize;
    loop {
        match std::future::poll_fn(|cx| std::pin::Pin::new(&mut body).poll_frame(cx)).await {
            None => break,
            Some(Err(_)) => {
                return StatusCode::BAD_REQUEST.into_response();
            }
            Some(Ok(frame)) => {
                if let Some(data) = frame.data_ref() {
                    seen += data.len();
                    if seen <= MEASURE_LIMIT_BYTES {
                        kept.extend_from_slice(data);
                    }
                }
            }
        }
    }
    let request_body_bytes = seen.min(MEASURE_LIMIT_BYTES);

    let response = next.run(Request::from_parts(parts, Body::from(kept))).await;

    // Measure the response as it will be written: split it, count the body, then put it back
    // together unchanged.
    let (parts, body) = response.into_parts();
    let response_headers = headers_of(&parts.headers);
    let Ok(bytes) = to_bytes(body, MEASURE_LIMIT_BYTES).await else {
        // The body could not be collected (a stream that failed): the exchange is still recorded,
        // with what was known of it, rather than dropped.
        log.record(Exchange {
            method,
            path,
            request_headers,
            request_body_bytes,
            status: parts.status.as_u16(),
            response_headers,
            response_body_bytes: 0,
        });
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let response_body_bytes = bytes.len();

    log.record(Exchange {
        method,
        path,
        request_headers,
        request_body_bytes,
        status: parts.status.as_u16(),
        response_headers,
        response_body_bytes,
    });

    Response::from_parts(parts, Body::from(bytes))
}

fn headers_of(headers: &HeaderMap) -> Vec<(String, String)> {
    headers
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_owned(),
                // A header value that is not text is shown as its bytes escaped rather than
                // dropped: it is still part of the message, so it must still be counted here.
                value
                    .to_str()
                    .map_or_else(|_| format!("{:?}", value.as_bytes()), ToOwned::to_owned),
            )
        })
        .collect()
}

/// The header name used to select a variant, if present.
#[must_use]
pub fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(n, _)| n == name)
        .map(|(_, v)| v.as_str())
}

/// A header name for tests and builders.
#[must_use]
pub fn name(s: &str) -> HeaderName {
    HeaderName::from_bytes(s.as_bytes()).unwrap_or_else(|_| HeaderName::from_static("x-invalid"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exchange() -> Exchange {
        Exchange {
            method: "POST".to_owned(),
            path: "/rpc/procedure.listNotes".to_owned(),
            request_headers: vec![
                ("content-type".to_owned(), "application/cbor".to_owned()),
                ("accept".to_owned(), "application/cbor".to_owned()),
            ],
            request_body_bytes: 10,
            status: 200,
            response_headers: vec![("content-type".to_owned(), "application/cbor".to_owned())],
            response_body_bytes: 20,
        }
    }

    #[test]
    fn the_request_line_is_counted() {
        let e = exchange();
        // Derived from the parts rather than written as one number: `"POST "` is 5 bytes, the path
        // is 24, `" HTTP/1.1"` is 9 and the line ending is 2.
        let expected = e.method.len() + 1 + e.path.len() + " HTTP/1.1".len() + 2;
        assert_eq!(e.request_line_bytes(), expected);
        assert_eq!(e.request_line_bytes(), 5 + 24 + 9 + 2);
        assert_eq!(e.request_line(), "POST /rpc/procedure.listNotes HTTP/1.1");
    }

    #[test]
    fn the_request_line_uses_the_method_that_arrived() {
        let mut e = exchange();
        // `GET` is 3 bytes where `POST` is 4, and `DELETE` is 6: a hard-coded `POST` would be wrong
        // for both.
        e.method = "GET".to_owned();
        assert_eq!(e.request_line(), "GET /rpc/procedure.listNotes HTTP/1.1");
        assert_eq!(e.request_line_bytes(), 3 + 1 + 24 + 9 + 2);
        e.method = "DELETE".to_owned();
        assert_eq!(e.request_line_bytes(), 6 + 1 + 24 + 9 + 2);
    }

    #[test]
    fn the_status_line_has_the_reason_hyper_writes() {
        let mut e = exchange();
        // `403` and `415` are statuses a refused call can get (a bearer the server rejects, a
        // media type the codec does not take); they were missing from an earlier hand-written table
        // and were counted with an empty reason, 9 and 22 bytes short.
        for (status, line) in [
            (200, "HTTP/1.1 200 OK"),
            (400, "HTTP/1.1 400 Bad Request"),
            (401, "HTTP/1.1 401 Unauthorized"),
            (403, "HTTP/1.1 403 Forbidden"),
            (404, "HTTP/1.1 404 Not Found"),
            (413, "HTTP/1.1 413 Payload Too Large"),
            (415, "HTTP/1.1 415 Unsupported Media Type"),
            (422, "HTTP/1.1 422 Unprocessable Entity"),
            (500, "HTTP/1.1 500 Internal Server Error"),
            // A status with no canonical reason: hyper writes `<none>`.
            (299, "HTTP/1.1 299 <none>"),
        ] {
            e.status = status;
            assert_eq!(e.status_line(), line);
            assert_eq!(e.status_line_bytes(), line.len() + 2, "{line}");
        }
    }

    #[test]
    fn every_header_is_counted_with_its_line_ending() {
        let e = exchange();
        // Each header is `name + ": " + value + CRLF`, summed from the parts for the same reason
        // as above: a hand-added constant hides an error instead of catching it.
        let expected: usize = e
            .request_headers
            .iter()
            .map(|(n, v)| n.len() + 2 + v.len() + 2)
            .sum();
        assert_eq!(
            e.request_head_bytes() - e.request_line_bytes() - 2,
            expected
        );
        // And the block really is those two headers:
        //   "content-type: application/cbor\r\n" = 12 + 2 + 16 + 2 = 32
        //   "accept: application/cbor\r\n"       =  6 + 2 + 16 + 2 = 26
        assert_eq!(expected, 32 + 26);
    }

    #[test]
    fn the_total_is_head_plus_body() {
        let e = exchange();
        assert_eq!(
            e.request_total_bytes(),
            e.request_head_bytes() + e.request_body_bytes
        );
        assert_eq!(
            e.response_total_bytes(),
            e.response_head_bytes() + e.response_body_bytes
        );
    }

    #[test]
    fn an_authorization_header_is_reported_separately() {
        let mut e = exchange();
        assert!(!e.has_authorization());
        assert_eq!(e.authorization_bytes(), 0);

        let value = "Bearer abc.def.ghi";
        e.request_headers
            .push(("authorization".to_owned(), value.to_owned()));
        assert!(e.has_authorization());
        // "authorization: Bearer abc.def.ghi\r\n" = 13 + 2 + 18 + 2 = 35.
        //
        // The literal is written *after* measuring the value, not guessed: `"Bearer abc.def.ghi"`
        // is 18 bytes ("Bearer " is 7, "abc.def.ghi" is 11), and the first two versions of this
        // line said 16 and then 15. The derived assertion above is the one that matters; this one
        // pins the exact number so a change to `authorization_bytes` is visible.
        assert_eq!(
            e.authorization_bytes(),
            "authorization".len() + 2 + value.len() + 2
        );
        assert_eq!(value.len(), 18);
        assert_eq!(e.authorization_bytes(), 35);
    }

    #[test]
    fn a_partial_log_is_not_a_lost_log() {
        let log = ExchangeLog::new();
        assert!(log.is_empty());
        log.record(exchange());
        assert_eq!(log.len(), 1);
        assert_eq!(log.exchanges()[0].status, 200);
        log.clear();
        assert!(log.is_empty());
    }
}
