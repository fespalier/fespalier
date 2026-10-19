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
  response. Real, and less dramatic than "CBOR is half the size" — most of that 33 is headers and
  framing, not payload, and the payload difference is a _fixed_ ~14-16 bytes (see
  [does it scale?](#does-it-scale) — it does not).
- **A `cose` run sends 101 more request bytes than plain CBOR** (1606 vs 1505) — but that total hides
  the interesting part. Read the [head/body split](#the-head-and-the-body-move-in-opposite-directions)
  before drawing a conclusion from it.
- **The credential moves, it does not shrink.** The `Bearer` header is 696 bytes over the run (6
  calls × 116 bytes: a 99-byte JWT value plus its name and line endings); the `cose` signature is
  557 over 5 sealed calls. The point is not that one is smaller — it is that the `cose` one is
  _verified_, and the `Bearer` one here is not (the server accepts any token; see below).

### The head and the body move in opposite directions

This is the table an eye comparing two payloads is really reading, and it is the one that is easiest
to get wrong from a total:

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

For the same call, a `cose` one has a **much thinner head** — it sends no `Authorization` header
(116 bytes saved) and pays only a longer `content-type` (40 vs 16 bytes) — and a **much fatter body**,
the payload plus the ~111 bytes of signature and protected header. So:

- **If you look at headers, `cose` is thinner.** That is a real observation, not an illusion.
- **If you look at the whole call, `cose` is bigger**, by the difference between the two.

Both are true, of different halves. A report that gave only the total would let the first observation
look like a mistake, which is why both tables are here.

### The signature against the token it replaces

The headline, stated directly:

| Credential       |   Bytes | Where       |
| ---------------- | ------: | ----------- |
| `Bearer` header  | **116** | in the head |
| `cose` signature | **111** | in the body |

**Signing roughly _replaces_ a token rather than adding to it.** The 64-byte ESP256 signature plus its
protected header lands within a few bytes of the `Bearer` header it displaces, so a signed call costs
about the same as a token-authenticated one — and the `cose` one is actually verified. What signing
costs is _not_ +111 bytes on top of a token; it is ~111 bytes _instead of_ ~116.

The `registerDevice` row is the exception that proves it: that call carries **no credential at all**
on the `cose` server (a device has to identify itself before it can sign), so `cose` wins there
outright — 206 against 331.

Per op, so the shape of the scenario is visible and not only its total:

| Op                         | Call |          JSON |          CBOR |          COSE |
| -------------------------- | ---: | ------------: | ------------: | ------------: |
| `procedure.registerDevice` |    1 | 1 × 331 = 331 | 1 × 322 = 322 | 1 × 206 = 206 |
| `procedure.addNote`        |    2 | 2 × 263 = 526 | 2 × 257 = 514 | 2 × 301 = 602 |
| `procedure.listNotes`      |    3 | 3 × 227 = 681 | 3 × 223 = 669 | 3 × 266 = 798 |

`registerDevice` is the one op a `cose` server leaves **plain** (a device has to identify itself
before it can sign), and it is the only row where `cose` is smallest — it is plain CBOR carrying no
header, where the other two carry the `Authorization` header. Every signed row is larger.

## What about JSON?

JSON is the largest body of the three, and by a **constant, not a proportion**:

| Variant | Body bytes (default scenario) |                JSON's penalty |
| ------- | ----------------------------: | ----------------------------: |
| `json`  |                           241 |                             — |
| `cbor`  |                           208 |                   +33 vs CBOR |
| `cose`  |                           765 | n/a (the signature is inside) |

The 33 bytes above are the _whole_ body difference over a 7-call scenario, and the per-message
figure is a **fixed ~12-16 bytes** (see [does it scale?](#does-it-scale)). It is structural: CBOR
spends one byte on a map head where JSON spends `{"args":{`, and it needs no closing braces or
quotes. A 25-byte JSON body and its 18-byte CBOR twin:

```
{"args":{"text":"hello"}}          # 25 bytes
a1 64 61726773 a1 64 74657874 ...  # 18 bytes — one-byte map heads, length-prefixed strings
```

**JSON is not bloated here, and CBOR is not magic.** The encoder is the same one in both cases and
the payload is a string either way; only the _framing_ around it differs. So on a 4 KB note JSON
costs 14 bytes more — **0.3%**. Anyone expecting "CBOR halves your payload" will be disappointed,
and anyone expecting "JSON costs 14 extra bytes and that is all" will be right.

## Does it scale?

The single most useful table here, because it answers the question a single payload size cannot:

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

(Bodies include the one `registerDevice` call the sweep also sends, which is why a 55 KB note gives a
56 KB body.)

**Neither penalty grows — and JSON's actually shrinks.** JSON's is +16 bytes at 16 bytes of note and
**+12** at 300 KB (the CBOR length prefix grows, eating into JSON's advantage); the signature stays
**+112 to +115** throughout. Both are _fixed structural costs_, so the percentage collapses:

| Payload | JSON vs CBOR | Signing vs CBOR |
| ------: | -----------: | --------------: |
|    16 B |    **12.0%** |       **84.2%** |
|    4 KB |        0.33% |            2.7% |
|   55 KB |       0.025% |           0.20% |
|  120 KB |       0.010% |          0.093% |
|  300 KB |   **0.004%** |      **0.037%** |

**On a 300 KB payload, CBOR saves 12 bytes — 0.004% — and signing costs 115 bytes — 0.037%.** Anyone
reaching for CBOR to shrink a large payload will be disappointed; anyone reaching for it to make many
small calls leaner will not. That inversion is the whole point of the table, and it is why a single
payload size is not evidence.

And the same is true of the credential: the ~112 bytes of signature against the 116-byte bearer
header are **fixed size**, so on a large payload neither a token nor a signature is worth optimising —
what matters at that point is the payload, and CBOR's ~14 bytes are noise beside it.

### It depends on what the payload is _made of_

The table above is the same three kinds of text, and they agree. **A fourth kind does not**, and it is
the one real payloads are most likely to resemble:

| Payload kind                                 | 300 KB: JSON−CBOR | JSON vs CBOR |
| -------------------------------------------- | ----------------: | -----------: |
| repeated bytes (`"xxx…"`)                    |               +12 |       0.004% |
| prose                                        |               +12 |       0.004% |
| base64                                       |               +12 |       0.004% |
| **escapable** (CRLF log, code, JSON-in-JSON) |       **+51,195** |   **+16.7%** |

JSON must escape `"`, `\`, `\n`, `\t` and **every control byte** — a single `\u0001` is six
characters for one. CBOR passes all of them through raw. So on text that is mostly escapable, JSON's
penalty is not 12 bytes: it is **roughly one extra byte per escaped character, and it grows with the
payload.**

This is the trap the first version of this sweep fell into: it built payloads with `"x".repeat(n)` —
one repeated byte, nothing to escape — and reported "JSON costs a fixed ~14 bytes" as though it were
general. It was a property of the one payload kind that has _nothing to escape_. **A degenerate
payload hid the only case where the answer changes.**

`tests/report.rs` pins all of it: that the signature is fixed for every kind, that JSON's penalty
does not grow on the three kinds with nothing to escape, and that it **does** grow on escapable text
— by an order of magnitude at least, and >10% of the body at 300 KB.

## Where the overhead goes

A delta of "101 bytes" is not an explanation. The report attributes it:

| Op                    | Payload | External AAD | Body |   Added | Added % |
| --------------------- | ------: | -----------: | ---: | ------: | ------: |
| `procedure.addNote`   |      43 |          102 |  155 |     112 |  260.5% |
| `procedure.listNotes` |       7 |          104 |  118 |     111 | 1585.7% |
| **Total**             | **107** |              |      | **557** |         |

- **Payload** is the CBOR the runner encoded — the thing being sent.
- **Added** is the body minus the payload: the protected header, the 64-byte ESP256 signature, and
  the CBOR framing around all three. About 111 bytes per call, near-constant, which is what a fixed-
  size signature looks like.
- **External AAD** is reported but **never counted**: it is reconstructed by the verifier from the
  binding and never crosses the wire. Adding it to the body would double-count bytes that do not
  exist, which is the one thing a byte-measuring example must not do. It is ~103 bytes per call, and
  it is part of why the fixed added cost is what it is.

The added percentage is large (260%, 1585%) because the payloads are tiny. At a realistic payload of
a few kilobytes the same ~111 bytes would be a few percent — which is the useful way to read it.

**Read "added" as the cost of the envelope, not as the cost of signing.** The ~111 bytes are what
the `COSE_Sign1` layer wraps around a payload. Whether that is _more_ than the alternative depends on
what it replaces, and it replaces a 116-byte `Bearer` header — see
[the signature against the token](#the-signature-against-the-token-it-replaces). Adding the two
numbers together (111 + 116) would be wrong twice over: it counts bytes that are not in the same
place, and it compares a variant that has a credential against one that would not.

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
- A real response also carries what hyper adds when it writes it: at least `date`, and
  `content-length` when the handler stack did not set one. None are counted.
- TCP and TLS framing is not counted.

Those additions are the same for every variant except the digits of `content-length` (a 7-byte body
and an 11-byte body differ by one digit), so the differences between variants hold to within that,
and every total is a lower bound.

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

**The `Bearer` token is not verified.** This server measures bytes; a real one would check the token,
and the plain variants would be refused outright without one (they have no signature to identify
their caller, so the baseline needs _a_ token to be authorized at all). The number that variant
produces is a realistic-_size_ header, not a working credential, and the report says so rather than
implying the baseline is production-shaped.

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
cargo run --release --bin wire-sizes-report              # the tables above
cargo run --release --bin wire-sizes-report > REPORT.md # regenerate the committed report
```

## Is the report trustworthy?

That is the question this example exists to answer, so it is answered structurally rather than by
assertion:

- **`REPORT.md` is generated and checked.** `server/tests/report.rs` compares the committed file with
  a fresh measurement, so a report that was not regenerated after a code change fails the build.
- **The numbers are deterministic.** Two runs produce byte-identical output; nothing here is
  timing-dependent.
- **The runner drives the router.** `server/tests/runner.rs` drives every variant through the whole
  scenario and asserts the statuses, the totals and the credential placement. A runner that built
  requests and never drove them would produce a report of zero bytes, so these assertions are on
  bytes that had to pass through the router to be counted.
- **The arithmetic is in the tests.** `measure.rs`'s own tests were written _after_ the first three
  attempts got the byte counts wrong by hand, and they now derive every constant from its parts.

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
| `server/src/main.rs`       | `--variant json\|cbor\|cose --listen ADDR`, and the hello line.                                         |
| `server/src/bin/report.rs` | `cargo run --bin wire-sizes-report`: the report, for `REPORT.md`.                                       |
| `server/REPORT.md`         | The generated report. Never edit it by hand; regenerate it.                                             |
| `server/deny.toml`         | The cli's licence policy plus what CrateStack's graph brings, as `examples/cose/server/deny.toml` does. |

## Not built

- **Realistic payload sizes.** Every payload here is tens of bytes, where framing dominates. The
  example measures a small call honestly; it says nothing about a 1 MiB body, where the percentage
  overhead would be tiny.
- **A verified `Bearer` token.** The baseline is realistic in _size_, not in behaviour. A server that
  checked the token would need a JWKS, and the scenario's setup would dominate its measurement.
- **`MEASURE_LIMIT_BYTES` (1 MiB).** A larger body is counted at the limit, so its size understates.
  The payloads here are far below it, and the tests assert that.
- **Three variants in one server** (`--variant`) rather than three servers. The comparison is between
  formats, not deployments; a reviewer may reasonably prefer three binaries.
