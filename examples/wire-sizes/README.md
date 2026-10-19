# wire-sizes: what a call costs in bytes, as JSON, CBOR and COSE_Sign1

A [fespalier](../../README.md) / [CrateStack](https://cratestack.dev) example that counts **what one
call costs in bytes, headers included**, as JSON, as plain CBOR, and as CBOR inside a `COSE_Sign1`
message. The count is of the HTTP message as the server's handler stack sees it. It is not a capture
of a socket, so it leaves out a few headers a real connection adds;
[where the measurement is taken](#where-the-measurement-is-taken) says which, and how large they are.

[`examples/cose`](../cose/README.md) shows _how_ to sign every request with a device key. This asks
what that costs against the alternatives a person weighs.

## The numbers

One scenario — register a device, write two notes, read them back three times — driven through all
three variants. A layer in the server ([`server/src/measure.rs`](server/src/measure.rs)) counts each
request as the router received it and each response as the router produced it: the request or status
line, the headers and the body. It does not count `host`, `content-length`, hyper's `date` or TCP/TLS
framing, so every total below is a lower bound. The differences between variants are exact to within
the digits of `content-length` (see [where the measurement is taken](#where-the-measurement-is-taken)).

| Variant | Credential             | Request bytes | Response bytes | Request body | Credential bytes |
| ------- | ---------------------- | ------------: | -------------: | -----------: | ---------------: |
| `json`  | `Authorization` header |          1538 |            827 |          241 |              696 |
| `cbor`  | `Authorization` header |          1505 |            757 |          208 |              696 |
| `cose`  | signature in the body  |          1606 |           1302 |          765 |              557 |

Reading that table:

- **CBOR saves 33 bytes of request over JSON** (1505 vs 1538) on these payloads, and 70 on the
  response. All 33 are in the body (241 vs 208 bytes): the headers are the same size. Per call the
  body differs by 9 bytes for `registerDevice`, 6 for `addNote` and 4 for `listNotes` (see the table
  below), so this is far from "CBOR is half the size". (`application/json` and `application/cbor`
  are both 16 bytes, so the `content-type` and `accept` headers do not differ.)
- **A `cose` run sends 101 more request bytes than plain CBOR** (1606 vs 1505), but that total adds
  two things that move in opposite directions. Read the
  [head/body split](#the-head-and-the-body-move-in-opposite-directions) before drawing a conclusion
  from it.
- **The credential moves; it does not shrink much.** The `Bearer` header is 696 bytes over the run
  (6 calls × 116 bytes: the 13-byte name `authorization`, a colon and a space, a 99-byte value made of
  `Bearer`, a space and a 92-byte JWT, and the line ending); the `cose` signature and its protected
  header are 557 over 5 sealed calls. What differs is that the `cose` one is verified, and the
  `Bearer` one here is not (the server accepts any token; see [the variants](#the-variants)).

### The head and the body move in opposite directions

The total above is a head plus a body, and the two halves differ between the variants in opposite
directions:

| Op                         | Variant | Head/call | Body/call | Total/call | Credential   |
| -------------------------- | ------- | --------: | --------: | ---------: | ------------ |
| `procedure.registerDevice` | `json`  |       221 |       110 |        331 | 116 B header |
| `procedure.registerDevice` | `cbor`  |       221 |       101 |        322 | 116 B header |
| `procedure.registerDevice` | `cose`  |       105 |       101 |        206 | in the body  |
| `procedure.addNote`        | `json`  |       214 |        49 |        263 | 116 B header |
| `procedure.addNote`        | `cbor`  |       214 |        43 |        257 | 116 B header |
| `procedure.addNote`        | `cose`  |       146 |       155 |        301 | in the body  |
| `procedure.listNotes`      | `json`  |       216 |        11 |        227 | 116 B header |
| `procedure.listNotes`      | `cbor`  |       216 |         7 |        223 | 116 B header |
| `procedure.listNotes`      | `cose`  |       148 |       118 |        266 | in the body  |

For the same call, a `cose` one has a **thinner head**: it sends no `Authorization` header (116
bytes saved) and pays for longer `content-type` and `accept` values (40 bytes each against 16: 48
more in all), so 68 bytes less. And it has a **fatter body**: the payload plus about 111 bytes of
signature and protected header. So:

- **Counting headers only, `cose` is thinner.**
- **Counting the whole call, `cose` is bigger**: for `addNote`, 112 more bytes of body less 68 of
  head is 44 more (301 against 257).

Both are true, of different halves; the total alone shows only the second.

### The signature against the token it replaces

The credential's own bytes, compared:

| Credential       |   Bytes | Where       |
| ---------------- | ------: | ----------- |
| `Bearer` header  | **116** | in the head |
| `cose` signature | **111** | in the body |

**Signing roughly _replaces_ a token rather than adding to it.** The 64-byte ESP256 signature plus
its protected header (about 111 bytes) is within a few bytes of the 116-byte `Bearer` header it
displaces, and the `cose` one is verified. What signing adds over a token is therefore not 111 bytes
but the 48 bytes of longer `content-type` and `accept` values, less the 4 or 5 bytes by which the
signature is smaller than the header: 43 to 44 more per sealed call in this scenario (`addNote` 301
against 257, `listNotes` 266 against 223).

`registerDevice` is the exception: on the `cose` server it carries no credential at all (a device has
to identify itself before it can sign) and goes as plain CBOR, so the `cose` call is the smallest of
the three there: 206 against 322 for CBOR and 331 for JSON.

Per op, so the shape of the scenario is visible and not only its total:

| Op                         | Call |          JSON |          CBOR |          COSE |
| -------------------------- | ---: | ------------: | ------------: | ------------: |
| `procedure.registerDevice` |    1 | 1 × 331 = 331 | 1 × 322 = 322 | 1 × 206 = 206 |
| `procedure.addNote`        |    2 | 2 × 263 = 526 | 2 × 257 = 514 | 2 × 301 = 602 |
| `procedure.listNotes`      |    3 | 3 × 227 = 681 | 3 × 223 = 669 | 3 × 266 = 798 |

`registerDevice` is the only row where `cose` is smallest. Every signed row is larger than the
plain CBOR one.

## What about JSON?

JSON's body is larger than plain CBOR's, and for ordinary text by a few bytes per message, not by a
proportion:

| Variant | Body bytes (default scenario) |                JSON's penalty |
| ------- | ----------------------------: | ----------------------------: |
| `json`  |                           241 |                             — |
| `cbor`  |                           208 |                   +33 vs CBOR |
| `cose`  |                           765 | n/a (the signature is inside) |

The 33 bytes are the whole body difference over the scenario's 6 calls: 9 for `registerDevice`, 6
for each `addNote` and 4 for each `listNotes` (9 + 2 × 6 + 3 × 4). It is structural: JSON spends two
bytes on a pair of braces, one on each colon and two on the quotes of each string, where CBOR spends
one byte on each map head and string head. A 25-byte JSON body and its 18-byte CBOR twin (12 bytes of
syntax against 5):

```text
{"args":{"text":"hello"}}          # 25 bytes
a1 64 61726773 a1 64 74657874 ...  # 18 bytes — one-byte map heads, length-prefixed strings
```

The payload is a string either way; only the syntax around it differs. So in the sweep below, whose
two calls are a registration and one note, JSON costs 14 bytes more than CBOR for a 4 KB note: 0.33%
of the CBOR body. That holds for text JSON does not have to escape;
[text that it does](#it-depends-on-what-the-payload-is-made-of) is another matter.

## Does it scale?

The same measurement at several payload sizes, which a single payload size cannot show. Each row is
one `registerDevice` (about 100 bytes) and one `addNote` carrying `note_text`; KB means 1024 bytes,
and the bodies are the sums over those two calls. The text is the `repeated` kind; `prose` and
`base64` give the same figures (all three are in `REPORT.md`):

|     `note_text` | JSON body | CBOR body | JSON−CBOR | COSE body | COSE−CBOR |
| --------------: | --------: | --------: | --------: | --------: | --------: |
|              16 |       149 |       133 |       +16 |       245 |      +112 |
|              64 |       197 |       182 |       +15 |       294 |      +112 |
|             256 |       389 |       375 |       +14 |       488 |      +113 |
|            1024 |      1157 |      1143 |       +14 |      1256 |      +113 |
|            4096 |      4229 |      4215 |       +14 |      4328 |      +113 |
|   55 KB (56320) |     56453 |     56439 |       +14 |     56552 |      +113 |
| 120 KB (122880) |    123013 |    123001 |       +12 |    123116 |      +115 |
| 300 KB (307200) |    307333 |    307321 |       +12 |    307436 |      +115 |

For this text, neither penalty grows with the payload, and JSON's shrinks slightly. JSON's is +16
bytes at 16 bytes of note and +12 at 300 KB (CBOR's string length prefix grows from one byte to five,
which takes away part of JSON's overhead); the signature stays at +112 to +115. Both are fixed costs,
so as a share of the CBOR body they fall with the payload:

| Payload | JSON over CBOR | Signing over CBOR |
| ------: | -------------: | ----------------: |
|    16 B |          12.0% |             84.2% |
|    4 KB |          0.33% |              2.7% |
|   55 KB |         0.025% |             0.20% |
|  120 KB |         0.010% |            0.093% |
|  300 KB |         0.004% |            0.037% |

On a 300 KB payload of this kind, CBOR saves 12 bytes (0.004%) and signing costs 115 (0.037%). The
same two costs are 12% and 84% of a 16-byte note. So CBOR shrinks a call made of small payloads by a
visible share and a large payload of plain text by almost nothing, and the credential, 111 bytes
against 116, is a fixed size that matters only while the payload is small.

### It depends on what the payload is made of

The table above is one kind of text, and `prose` and `base64` agree with it. A fourth kind does not:

| Payload kind                          | 300 KB: JSON−CBOR | JSON over CBOR |
| ------------------------------------- | ----------------: | -------------: |
| `repeated` (`"xxx…"`)                 |               +12 |         0.004% |
| `prose`                               |               +12 |         0.004% |
| `base64`                              |               +12 |         0.004% |
| `escapable` (a tab-indented CRLF log) |           +51,195 |          16.7% |

JSON must escape `"`, `\`, `\n`, `\t` and every control byte; a single `\u0001` is six characters
for one. CBOR passes all of them through raw. So on text that is mostly escapable, such as a log
with CRLF line endings and tab indents (the `escapable` kind), JSON's penalty is not 12 bytes: it is
about one extra byte per escaped character, and it grows with the payload. Whether a real payload is
closer to `prose` or to `escapable` depends on what it carries; the sweep does not say which is more
common, and it has no kind for non-ASCII text or for a payload that is itself JSON.

`tests/report.rs` pins this: the signature is fixed for every kind, JSON's penalty does not grow on
the three kinds with nothing to escape, and it does grow on `escapable` text, by more than ten times
between 1 KB and 300 KB and to more than a tenth of the body at 300 KB.

## Where the overhead goes

A delta of "101 bytes" does not say where the bytes are. The report attributes the sealed calls'
bytes, per op here (`REPORT.md` has one row per call):

| Op                    | Payload | External AAD | Body |   Added | Added % |
| --------------------- | ------: | -----------: | ---: | ------: | ------: |
| `procedure.addNote`   |      43 |          102 |  155 |     112 |  260.5% |
| `procedure.listNotes` |       7 |          104 |  118 |     111 | 1585.7% |
| **Total**             | **107** |              |      | **557** |         |

- **Payload** is the CBOR the runner encoded — the thing being sent.
- **Added** is the body minus the payload: the protected header, the 64-byte ESP256 signature, and
  the CBOR framing around all three. About 111 bytes per call, near-constant, as a fixed-size
  signature would be.
- **External AAD** is reported but **never counted**: the signature covers it, but the verifier
  rebuilds it from the binding and it is not sent. Adding it to the body would count bytes that are
  not in the message. It is ~103 bytes per call.

The added percentage is large (260%, 1585%) because the payloads are tiny. At a payload of a few
kilobytes the same ~111 bytes are a few percent (2.7% of a 4 KB CBOR body, from the table above).

"Added" is the cost of the envelope, not of signing as such: the ~111 bytes are what the `COSE_Sign1`
layer wraps around a payload. Whether that is more than the alternative depends on what it replaces,
and it replaces a 116-byte `Bearer` header (see
[the signature against the token](#the-signature-against-the-token-it-replaces)). The two do not add:
a sealed call carries the 111 bytes and no `Authorization` header, a plain one carries the header.

## Where the measurement is taken

The runner never opens a socket. It builds each request itself (a request line, `content-type`,
`accept`, an `authorization` header for the plain variants, and the body) and hands it to the
server's router with `tower::ServiceExt::oneshot`
([`server/src/runner.rs`](server/src/runner.rs)). A middleware that wraps the whole router
([`server/src/measure.rs`](server/src/measure.rs)) records the request as the router receives it and
the response as the router returns it, before hyper would write either to a connection.

So a count is **the HTTP message as the handler stack sees it**, with two lines rebuilt: the request
line from the method and the path, and the status line from the status code and its standard reason
phrase, because no middleware sees either. It is not the bytes on a socket:

- A real HTTP/1.1 request also carries `host` and `content-length`, and whatever else its client
  adds (`user-agent`, `accept-encoding`, cookies). The runner sends none of them, so none are counted.
- A real response also carries what hyper adds when it writes it. For this server that is
  `content-length` (the handler stack sets none) and `date`. Neither is counted.
- TCP and TLS framing is not counted.

Those additions are the same for every variant except the digits of `content-length` (a 7-byte body
and an 11-byte body differ by one digit), so the differences between variants hold to within that,
and every total is a lower bound.

[`server/tests/socket.rs`](server/tests/socket.rs) pins this against hyper. It sends the request the
runner builds over a TCP connection to the same router, served by `axum::serve`, with `host` and
`content-length` added as any HTTP/1.1 client adds them. It does this for `registerDevice` in all
three variants and for `listNotes` in JSON and CBOR (a sealed call needs the device key, which the
runner keeps to itself, so the `cose` server is exercised through its plain `registerDevice`). It
asserts that:

- the exchange's request count equals the number of bytes written to the socket, so the rebuilt
  request line is exact;
- over a socket the stack receives two more request headers than in process, `host` and
  `content-length`, and no others;
- hyper adds two response headers to what the stack set, `content-length` and `date`, and no others,
  and the status line is the one the exchange rebuilds;
- JSON against CBOR for the same call differs over a socket from the in-process difference by the
  digits of `content-length` and by nothing else, on both sides.

Per call, a socket adds:

| Side     | Header                | Bytes                                                 |
| -------- | --------------------- | ----------------------------------------------------- |
| request  | `host: <host>`        | 8 + the length of the host (23 for `127.0.0.1:50000`) |
| request  | `content-length: <n>` | 18 + the digits of `n`                                |
| response | `content-length: <n>` | 18 + the digits of `n`                                |
| response | `date: <HTTP date>`   | 37 (an HTTP date is always 29 bytes)                  |

A client adds more of its own (`user-agent`, `accept-encoding`), and TLS adds record framing. For the
six calls of the scenario, the `host` and `content-length` lines alone are 6 × (23 + 18) = 246 request
bytes plus the digits of each `content-length` (10 for CBOR, 13 for JSON, 18 for `cose`, from the body
sizes in the table above): about 17% of the CBOR run's 1505. The response side is at least
6 × (18 + 37) = 330 bytes plus a digit per call, more than 40% of its 757. The digits also move the
differences: over a socket the JSON request would be 36 bytes larger than CBOR's, not 33, and the
`cose` one 109 larger, not 101. The totals in this example are for comparing variants with each other,
not for predicting a bill.

Two more properties of the measurement:

- **The measurement layer is outermost.** A refusal from the envelope layer or the codec (`401`,
  `400`, `415`) is an exchange with a size, and it is weighed like any other. The scenario has none:
  every call is a `POST` that answers `200`.
- **The request and status lines are rebuilt** from the method, the path and the status, as above.
  For one op they are the same in every variant, so they do not move a comparison.

## The variants

| Variant | Body                                                     | Credential                                              |
| ------- | -------------------------------------------------------- | ------------------------------------------------------- |
| `json`  | `application/json`                                       | none, unless the caller sends `Authorization: Bearer …` |
| `cbor`  | `application/cbor`                                       | none, unless the caller sends `Authorization: Bearer …` |
| `cose`  | `application/cose; cose-type="cose-sign1"` wrapping CBOR | the signature in the body                               |

**The `Bearer` token is not verified.** This server measures bytes; a real one would check the token.
The plain variants have no signature to identify their caller, so `addNote` and `listNotes` are
refused with a `403` unless a request carries some `Authorization: Bearer` value (`registerDevice`
needs none). The baseline sends a 92-byte JWT-shaped string, so the header is a realistic size, but it
is not a working credential, and `REPORT.md` says so.

## Run it

The server (Rust, the toolchain in `server/rust-toolchain.toml`):

```sh
cd server
cargo run --locked -- --variant cbor --listen 127.0.0.1:8787
# {"addr":"127.0.0.1:8787","audience":"","server_public_jwk":null,"variant":"cbor"}
```

It prints one JSON line when it listens, then serves until killed. `--variant` is `json`, `cbor` or
`cose`; the `cose` variant is the only one with an audience and a `server_public_jwk`.

The measurement, which needs no running server — it drives the router in process (no socket) so it
can read the server's own log back:

```sh
cd server
cargo run --locked --quiet --bin wire-sizes-report              # the tables above
cargo run --locked --quiet --bin wire-sizes-report > REPORT.md  # regenerate the committed report
```

## What checks the report

- **`REPORT.md` is generated and checked.** `server/tests/report.rs` compares the committed file with
  a fresh measurement, so a report that was not regenerated after a code change fails the build.
- **The numbers are deterministic.** Two runs produce byte-identical output: nothing here depends on
  timing, and the random keys have a fixed size.
- **The runner drives the router.** `server/tests/runner.rs` drives every variant through the whole
  scenario and asserts the statuses, the totals and the credential placement. A runner that built
  requests and never drove them would produce a report of zero bytes, so these assertions are on
  bytes that had to pass through the router to be counted.
- **The arithmetic is in the tests.** `measure.rs`'s unit tests derive each count from its parts
  (the request line, each header line, the status line for a range of statuses) instead of writing
  a total.
- **The gap to a socket is in a test.** `server/tests/socket.rs` (see
  [where the measurement is taken](#where-the-measurement-is-taken)) compares the in-process count
  with bytes written to and read from a real TCP connection. It writes the HTTP by hand and does not
  use an HTTP client, so the headers a client adds on its own are not covered.

## What is in it

| Path                       | What it is                                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------------- |
| `server/schema.cstack`     | One contract, served by all three variants.                                                             |
| `server/src/measure.rs`    | The measuring layer: each request as the router received it, each response as it produced it.           |
| `server/src/registry.rs`   | The device registry, and the envelope layer's `CoseVerifierResolver`.                                   |
| `server/src/lib.rs`        | `Variant`, the procedures, and `build` (the envelope only for `cose`).                                  |
| `server/src/runner.rs`     | The scenario driver: the same calls, every variant, in process (no socket).                             |
| `server/src/scenario.rs`   | `Scenario` and `Run`, and the envelope overhead's attribution.                                          |
| `server/src/report.rs`     | The measurement rendered as Markdown.                                                                   |
| `server/src/payload.rs`    | Payload shapes and text kinds, sent by the `measurePayload` op through `runner::run_payload`.           |
| `server/src/main.rs`       | `--variant json\|cbor\|cose --listen ADDR`, and the hello line.                                         |
| `server/src/bin/report.rs` | `cargo run --bin wire-sizes-report`: the report, for `REPORT.md`.                                       |
| `server/tests/`            | `report.rs` (the report is fresh, its claims hold), `runner.rs`, `shapes_smoke.rs` and `socket.rs`.     |
| `server/REPORT.md`         | The generated report. Never edit it by hand; regenerate it.                                             |
| `server/deny.toml`         | The cli's licence policy plus what CrateStack's graph brings, as `examples/cose/server/deny.toml` does. |

## Not built

- **Payloads past 300 KB in the report.** The scenario's payloads are tens of bytes and the sweeps
  stop at 300 KB. `tests/shapes_smoke.rs` sends a 1 MiB payload to check that the measuring layer
  passes it on whole, but no report row has one.
- **Payload shapes in the report.** `src/payload.rs` and the `measurePayload` op can send a list of
  records, a nested object or a blob, and `tests/shapes_smoke.rs` runs them; the report's sweeps still
  send one string in an `addNote`.
- **Compression and HTTP/2.** The counts are of uncompressed HTTP/1.1 text: no `content-encoding`
  and no header compression.
- **A real client.** The runner and the socket test build HTTP by hand, so the headers an HTTP
  client adds on its own (`user-agent`, `accept-encoding`) are not counted.
- **A verified `Bearer` token.** The baseline is realistic in size, not in behaviour. Checking the
  token would need a key set and a signing step that this example does not have.
- **A body past `MEASURE_LIMIT_BYTES`.** A body larger than the router's 2 MiB limit plus 4 MiB is
  counted at that sum, so its size is understated. The router refuses anything over 2 MiB, and the
  largest body in the report is about 300 KB.
- **Three variants in one server** (`--variant`) rather than three servers. The comparison is between
  formats, not deployments; a reviewer may prefer three binaries.
