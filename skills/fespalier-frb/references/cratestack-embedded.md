# CrateStack in the Rust core

A [CrateStack](https://cratestack.dev) schema (`.cstack`) generates Rust for a server, a client and an embedded store.
A Rust core can take either of the last two, and `fespalier_cratestack` (pure Dart, with no CrateStack or FRB dependency)
works over it through the seams it already has. CrateStack is pre-1.0: re-read its guide for the version you pin.

| The core is                               | fespalier_cratestack sees it as                     | Built in                                                                                      |
| ----------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| CrateStack's **generated Rust client**    | a `CrateStackTransport`                             | [`examples/frb-cose`](../../../examples/frb-cose/README.md) (since 0.21.1), CrateStack 0.15.3 |
| CrateStack's **embedded SQLite store**    | a `LocalStore`, or typed tables read in `data.dart` | no example: what follows is the package's seams and CrateStack's documentation                |
| a whole **sync core** (push, pull, drain) | a `SyncRunner`                                      | no example                                                                                    |

The wiring of `fespalier_cratestack` itself (the error reader, the answer table, idempotency, `ref.serve`, intents) is
the [`fespalier-cratestack`](../../fespalier-cratestack/SKILL.md) and [`fespalier-offline`](../../fespalier-offline/SKILL.md)
skills; this page is what changes when the CrateStack side is in Rust.

## The client in Rust (as frb-cose)

The core is the generated client of the **same schema file** the server is built from:

```rust
// rust/src/core/client.rs
cratestack::include_client_schema!("../server/schema.cstack");
```

```toml
# rust/Cargo.toml
[dependencies]
cratestack = { package = "cratestack-client", version = "=0.15.3", default-features = false, features = ["cose", "decimal-rust-decimal"] }
reqwest = { version = "0.13", default-features = false, features = ["rustls-no-provider"] }

[dev-dependencies]
frb-cose-demo-server = { path = "../server" }
cratestack_server = { package = "cratestack-api", version = "=0.15.3", default-features = false, features = ["cose"] }
```

- **`default-features = false`** keeps the facade's own HTTP stack out; the core builds its client (reqwest, redirects
  off, a connect and a total timeout) and hands it to CrateStack.
- **Rename every facade** (`package = "..."`): two crates whose library is called `cratestack` in one build is rustc's
  E0464.
- **An exact `=0.15.3` pins the facade only.** Its `cratestack-*` dependencies resolve to the newest patch unless the
  lockfile pins them; commit `Cargo.lock` and check that every `cratestack-*` in it is the version you meant (frb-cose's
  versions test reads the lockfiles).
- **The schema is shared by path.** A change to `schema.cstack` moves the client and the server together, and a
  contract test (`rust/tests/contracts.rs`) checks that the ops the core accepts are the server's `OP_CONTRACTS`.

**The Dart side is a `CrateStackTransport` over the core** (`lib/src/core_transport.dart`): it encodes an `RpcCall`'s
input as JSON, calls `core.call(op, argsJson, idempotencyKey)`, and reads the answer as CrateStack reads a server's:
a sealed 2xx is the result, a sealed non-2xx goes through `CrateStackFailure.fromResponse`, and each `CoreErrorKind` maps
to a failure (`Transport`, `Seal`, `Unverified`, `Registration` are `CrateStackOffline`, under the same key; `BadInput` is
an `ArgumentError`, nothing sent). The rule that decides the table: **a failure that is not the server's word is
offline, never unavailable**, because the write may have landed and a new key would run it twice.

So the split is:

| In Rust (the core)                                                          | In Dart                                                                 |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| the generated client, the sealing and opening (`cratestack-cose`), the HTTP | the pages, `ref.serve` and the read copy, the intent queue and its keys |
| the registration of the device, a journal with no payload, the events       | the device key (`fespalier_keypair`), called back to sign               |
| **never retries a request**                                                 | the intent queue decides when the next attempt goes                     |

One retry layer: the core sends once per `send`, and `fespalier_cratestack`'s intents (`<id>#<attempt>`) are the only
thing that sends again. `crateStackScope` is the account (frb-cose: the device key's thumbprint), so a new key is a new
account and its rows are apart.

## The embedded store in Rust

CrateStack's embedded mode generates a SQLite store from the same schema (`include_embedded_schema!` over `rusqlite`;
[cratestack.dev/guides/offline-first-sqlite](https://cratestack.dev/guides/offline-first-sqlite)). Inside the core it
fits two ways.

**As the `LocalStore`.** The interface is a key and value table:

```dart
abstract interface class LocalStore {
  FutureOr<String?> read(String key);
  FutureOr<void> write(String key, String value);
  FutureOr<void> writeAll(Map<String, String> entries);
  FutureOr<void> delete(String key);
  FutureOr<Iterable<String>> keys(String prefix);
  FutureOr<void> clear(String prefix);
}
```

Give the core a `kv` table in the schema (or a plain table beside it) and async `api/` functions for the six methods,
then a Dart class over them in `lib/src/` and `localStore.overrideWithValue(...)` in the overrides `startup()` returns
(after opening the core, so in `startup()` or `ready()`; the database path comes from the app's support directory, which
Dart knows and passes in `CoreConfig`). The rules the package states:

- **Never evict.** An intent never expires and an unpushed row is the only copy of an edit; no size budget, no TTL.
- **Wipe by prefix at sign-out** (`clear(prefix)`), which `ref.read(crateStackAccount).clear()` calls for the account.
- **One writer.** A second isolate (a background sync) needs a store that is safe to open twice; with SQLite that is
  WAL mode and a busy timeout, decided in Rust.
- **An FFI read is asynchronous**, so a `localOnly` read or a `cacheFirst` hit costs one `loading.dart` frame that the
  in-memory and Hive stores do not.

**As typed tables read in `data.dart`.** The core exposes typed reads (`list_notes() -> Vec<Note>`), and a `data.dart`
calls them and watches `crateStackRevision(tag)` so a sync that changed the rows rebuilds the read. A write the core
makes on its own (a server push it applied) should also emit an event on the core's stream, so a `ChangeFeed` topic can
move the page without waiting for a sync.

**As a whole sync core.** A core that pushes, pulls and drains implements `SyncRunner` (`Future<SyncReport>
sync(SyncReason reason)`, which must not throw) through one async `api/` function, and the app overrides `syncRunner`.
`autoSync`, its triggers, `Served` and `IntentOutcome` keep working; `SyncEngine` is skipped. The intent contract (the key
format and the answer table) is then the core's to keep, byte for byte, because the server's idempotency depends on it.

## What the embedded mode does not give you

- **A sync engine.** CrateStack documents none for the embedded mode, and `@@audit` and `@@emit` do nothing there: push,
  pull and merge are `RowSync` and `SyncEngine` in Dart, or your `SyncRunner`.
- **Decisions.** Policies are parsed but **not enforced** in the embedded mode: the device is untrusted, so every
  decision stays an intent the server makes.
- **The web.** The embedded wasm build needs OPFS in a dedicated worker, which Flutter's main isolate is not; and a
  native-assets web build has no core anyway. On the web use `InMemoryLocalStore` or `HiveLocalStore`.
- **A dependency of `fespalier_cratestack`.** FRB versions must match across an app and the bindings are the app's, so
  the package stays pure Dart and imports no CrateStack code.

## Client and store in one core

Both can live in one crate (the client for calls, the store for the copy), each facade renamed. Keep them in separate
`core/` modules with no type in common, so either can be dropped, and give `api/` one opaque handle that owns both.
Pin both to the same CrateStack version and check the lockfile. This combination is **not built** in any example: build
it with a test against the server in process, as frb-cose's `rust/tests/against_server.rs` does for the client.

## Layout additions

```text
rust/src/core/client.rs     include_client_schema!(...)        (client mode)
rust/src/core/store.rs      include_embedded_schema!(...)      (embedded mode)
rust/tests/contracts.rs     the core's ops are the server's
server/schema.cstack        the one schema, read by path by the server and the core
lib/src/core_transport.dart a CrateStackTransport over the core (client mode)
lib/src/core_store.dart     a LocalStore over the core (embedded mode)
```
