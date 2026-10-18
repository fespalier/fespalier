# wire-sizes: what a call costs, measured on the wire

A [fespalier](../../README.md) / [CrateStack](https://cratestack.dev) example whose whole point is a
number nobody has to take on trust: **what one call costs in bytes, headers included**, as JSON, as
plain CBOR, and as CBOR inside a `COSE_Sign1` message.

[`examples/cose`](../cose/README.md) shows _how_ to sign every request with a device key. This asks
what that costs against the alternatives a person actually weighs.

## The numbers

One scenario — register a device, write two notes, read them back three times — driven through all
three variants. Measured by the server, from what actually arrived, headers and framing included
([`server/src/measure.rs`](server/src/measure.rs)).

| Variant | Credential             | Request bytes | Response bytes | Request body | Credential bytes |
| ------- | ---------------------- | ------------: | -------------: | -----------: | ---------------: |
| `json`  | `Authorization` header |          1538 |            827 |          241 |              696 |
| `cbor`  | `Authorization` header |          1505 |            757 |          208 |              696 |
| `cose`  | signature in the body  |          1606 |           1302 |          765 |              557 |

Reading that table:

- **CBOR saves 33 bytes of request over JSON** (1505 vs 1538) on these payloads, and 70 on the
  response. Real, and less dramatic than "CBOR is half the size" — these payloads are small, and the
  byte counts are dominated by headers rather than by the payload.
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

## Why the measurement is on the server

A client cannot see its own inherited headers. `content-length`, `host` and the rest are added by
the stack on the way out, so a client that adds up the headers it _set_ reports a number that never
existed — and it would be wrong in a direction that flatters whichever variant is smallest, because
the omitted bytes are the same for all of them.

So the request side is measured by the server, from what arrived
([`server/src/measure.rs`](server/src/measure.rs)): the method, the path, every header as received,
and the exact body bytes. The response side is measured the same way, before hyper frames it.

Two consequences worth knowing:

- **The measurement layer is outermost.** A refusal from the envelope layer or the codec (`401`,
  `400`, `415`) is a real exchange with a real size, and it is weighed like any other. A comparison
  that measured only successful calls would be measuring something else.
- **The request and status lines are reconstructed**, because hyper adds them and no middleware sees
  them. They are constant across the variants, so leaving them out would shrink every variant by the
  same amount.

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

The measurement, which needs no running server — it drives the router in process so it can read the
server's own log back:

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
- **The runner sends for real.** `server/tests/runner.rs` drives every variant through the whole
  scenario and asserts the statuses, the totals and the credential placement — a runner that built
  requests and never drove them would produce a report of zero bytes, so these assertions are on
  bytes that had to cross a router to exist.
- **The arithmetic is in the tests.** `measure.rs`'s own tests were written _after_ the first three
  attempts got the byte counts wrong by hand, and they now derive every constant from its parts.

## What is in it

| Path                       | What it is                                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------------- |
| `server/schema.cstack`     | One contract, served by all three variants.                                                             |
| `server/src/measure.rs`    | The measurement: what arrived, what was sent, headers and body bytes.                                   |
| `server/src/registry.rs`   | The device registry, and the envelope layer's `CoseVerifierResolver`.                                   |
| `server/src/lib.rs`        | `Variant`, the procedures, and `build` (the envelope only for `cose`).                                  |
| `server/src/runner.rs`     | The scenario driver: the same calls, every variant, in process.                                         |
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
