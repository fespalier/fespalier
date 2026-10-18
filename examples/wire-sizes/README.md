# wire-sizes: what a call costs, measured on the wire

A [fespalier](../../README.md) / [CrateStack](https://cratestack.dev) example whose whole point is a
number nobody has to take on trust: **what one call costs in bytes, headers included**, as JSON, as
plain CBOR, and as CBOR inside a `COSE_Sign1` message.

[`examples/cose`](../cose/README.md) shows *how* to sign every request with a device key. This asks
what that costs against the alternatives a person actually weighs.

> **Scaffolding only, so far.** The server and the measurement are here and tested; the runner that
> drives a full scenario, the report, and its generator are not yet. The numbers below do not exist
> yet — nothing in this README claims one.

## Why the measurement is on the server

A client cannot see its own inherited headers. `content-length`, `host` and the rest are added by
the stack on the way out, so a client that adds up the headers it *set* reports a number that never
existed — and it would be wrong in a direction that flatters whichever variant is smallest, because
the omitted bytes are the same for all of them.

So the request side is measured by the server, from what arrived ([`src/measure.rs`](server/src/measure.rs)):
the method, the path, every header as received, and the exact body bytes. The response side is
measured the same way, before hyper frames it.

Two consequences worth knowing:

- **The measurement layer is outermost.** A refusal from the envelope layer or the codec (`401`,
  `400`, `415`) is a real exchange with a real size, and it is weighed like any other. A comparison
  that measured only successful calls would be measuring something else.
- **The request and status lines are reconstructed**, because hyper adds them and no middleware sees
  them. They are constant across the variants, so leaving them out would shrink every variant by the
  same amount.

## The variants

| Variant | Body | Credential |
| --- | --- | --- |
| `json` | `application/json` | none, unless the caller sends `Authorization: Bearer …` |
| `cbor` | `application/cbor` | none, unless the caller sends `Authorization: Bearer …` |
| `cose` | `application/cose; cose-type="cose-sign1"` wrapping CBOR | the signature in the body |

`json` and `cbor` also measure a **`Bearer` baseline**: the same call with a realistic
`Authorization` header. The token is **not verified** — this server measures bytes, and a real one
would check it. The number that variant produces is a realistic-*size* header, not a working
credential, and the report says so rather than implying the baseline is production-shaped.

## Run it

The server (Rust, the toolchain in `server/rust-toolchain.toml`):

```sh
cd server
cargo run --locked -- --variant cbor --listen 127.0.0.1:8787
# {"addr":"127.0.0.1:8787","audience":"","server_public_jwk":null,"variant":"cbor"}
```

It prints one JSON line when it listens, then serves until killed. `--variant` is `json`, `cbor` or
`cose`; the `cose` variant is the only one with an audience and a `server_public_jwk`.

## What is in it

| Path | What it is |
| --- | --- |
| `server/schema.cstack` | One contract, served by all three variants. |
| `server/src/measure.rs` | The measurement: what arrived, what was sent, headers and body bytes. |
| `server/src/registry.rs` | The device registry, and the envelope layer's `CoseVerifierResolver`. |
| `server/src/lib.rs` | `Variant`, the procedures, and `build` (the envelope only for `cose`). |
| `server/src/main.rs` | `--variant json\|cbor\|cose --listen ADDR`, and the hello line. |
| `server/deny.toml` | The cli's licence policy plus what CrateStack's graph brings, as `examples/cose/server/deny.toml` does. |

## Not built

- **The runner and the report.** Nothing measures a full scenario yet, so no number in this README
  is real. The next change adds both, and the report is generated rather than hand-written.
- **The signature's own cost**, split out: the report will break a `cose` message into its payload,
  its protected header, its 64-byte signature and the external AAD it binds, so the overhead is
  attributable rather than a single unexplained delta.
- **`MEASURE_LIMIT_BYTES` (1 MiB).** A larger body is counted at the limit, so its size understates.
  The payloads here are far below it, and the tests assert that.
- **Three variants in one server** (`--variant`) rather than three servers. The comparison is between
  formats, not deployments; a reviewer may reasonably prefer three binaries.
