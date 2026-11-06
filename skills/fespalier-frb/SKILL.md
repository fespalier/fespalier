---
name: fespalier-frb
description: "The common layout of a fespalier app whose logic lives in a Rust core behind flutter_rust_bridge (FRB) — the folders (rust/ with core/ pure Rust and api/ the bridge surface, lib/src/rust/ generated, one Dart seam over the generated object, hook/build.dart or rust_builder/), the rules each layer keeps (only structs, fieldless enums and an opaque handle cross; a Dart callback that catches everything and is never called from a sync function; fixed error kinds and no server text; RustLib.init in startup() through fespalier_frb's initRustCore; a web build that returns a fallback core before touching the bindings), the core's change stream as a ChangeFeed, the FRB pins kept exact, the tests at each layer (fakes of the seam, the real core on the host loaded by its path, a bindings boundary test, a regenerate-and-diff check), Cargokit against Flutter native assets (build hooks) as the build backend, and CrateStack inside the core (its generated Rust client as the transport, since 0.21.1, or its embedded SQLite mode as LocalStore or SyncRunner). Load before starting or restructuring a Flutter app with a Rust core, adding an FRB function, a stream or a callback, choosing or migrating between Cargokit and native assets, putting CrateStack in Rust, or when RustLib.init fails, a host test cannot find the library, a Dart callback panics or deadlocks the core, or generated bindings drift."
---

# fespalier-frb

> **Verified against fespalier `caf51165` (2026-10-31), release v0.25.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

A fespalier app with a **Rust core** keeps its pages, routes, offline copy and keys in Dart, and puts in Rust what Rust
does better: a protocol client, a parser, a signer, a store, a sync engine. [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)
(FRB) generates the bindings. fespalier adds **no file kind, no `fespalier:` key and no `fsp` command** for it: the core is
a provider like any other, overridden in `startup()`. This skill is the **layout** such an app should have, so that the
next one looks like the last. The worked case is [`examples/frb-cose`](../../examples/frb-cose/README.md) (since 0.21.1),
FRB 2.13.0 on Flutter 3.44 and later; every rule below is taken from it unless it says otherwise.

The Dart blocks on these pages are **sketches**: they name generated bindings that only exist in your app, so
`just skill-samples` does not build them. The real files are the example's.

## Should it be a Rust core?

- **Yes** when the work is already written in Rust (CrateStack's client, a COSE or JOSE library, a CRDT, a parser shared
  with a server), when it must behave the same on every platform and the server, or when it is CPU-bound.
- **No** for an HTTP client alone: [`fespalier_transport`](../fespalier-data/SKILL.md) (its `http.md` page) with Dio or `package:http`
  is visible to DevTools, the system proxy and the platform's TLS setup, and a Rust socket is not
  (frb-cose's README, "Not built").
- **Not on the web**, as built: a Flutter web build has **no code assets**, so no core. The app must still run there
  (read-only, or not at all) and say so. See [The web](#the-web).
- **Not for what the generator owns.** The core never decides routes, guards or data keys; `lib/app/` stays plain
  fespalier files, and `app.g.dart` is the same as without a core.

## The layout

```text
my_app/
  pubspec.yaml               flutter_rust_bridge: X.Y.Z (exact); flutter_rust_bridge_hooks: X.Y.Z with native assets
  flutter_rust_bridge.yaml   rust_input: crate::api, rust_root: rust/, rust_output, dart_output: lib/src/rust
  hook/build.dart            native assets: FlutterRustBridgeNativeAssetsBuilder(cratePath: 'rust')
  rust_builder/              Cargokit instead: the plugin package that builds rust/ (never both)
  rust/
    Cargo.toml, Cargo.lock   crate-type = ["cdylib", "staticlib", "rlib"]; flutter_rust_bridge = "=X.Y.Z"; lock committed
    rust-toolchain.toml      an exact channel, and every target you build for
    src/lib.rs               pub mod api; pub mod core; the generated module, allowed and unformatted
    src/core/                the engine: pure Rust, no FRB type, tested with cargo test
    src/api/                 the surface FRB reads: structs, fieldless enums, one opaque handle, From impls
    src/frb_generated.rs     GENERATED
    tests/                   the engine against a server in process, or fixtures
  lib/
    app/                     the fespalier tree; startup.dart opens the core and returns the overrides
    src/rust/                GENERATED (dart_output)
    src/core.dart            the seam: an interface, the data types re-exported, a fallback core, the provider
    src/frb_core.dart        the ONLY file that loads the library and wraps the generated object
    src/changes.dart         a ChangeFeed over core.changes()
    src/wiring.dart          the overrides startup() returns (and a test reuses with a fake)
  test/
    support/fakes.dart       a fake core: what every widget test uses
    support/host_core.dart   loads the real core by its file, for the host tests
    bindings_boundary_test.dart, core_ffi_test.dart, e2e_test.dart (skips unless its server is named)
  server/                    optional: a standalone crate the core is tested against (own Cargo.lock)
```

[`references/layout.md`](references/layout.md) goes through it file by file, with the skeleton of each.

## The rules

1. **Two Rust layers.** `core/` is the engine and knows nothing of FRB, so `cargo test` covers it and a Swift or
   Kotlin shell could reuse it. `api/` is thin: it converts the engine's types at the boundary (`From` impls) and is
   the only input of the codegen (`rust_input: crate::api`). The only FRB type `core/` may name is the callback's
   future, and frb-cose keeps even that behind its own type alias (`SignFn`).
2. **Only structs, fieldless enums and one opaque handle cross.** FRB turns an enum with data into a `freezed` class,
   which needs `build_runner` and drags it into the app: keep enums fieldless and put the data in a struct beside
   them (`CoreEvent { kind, op }`). Everything stateful is one opaque struct (`NotesCore`) with `open` and methods.
3. **Generated files are never edited**: `rust/src/frb_generated.rs` and `lib/src/rust/`. A change to `api/` is a
   regeneration, with the pinned codegen, and CI regenerates and fails on a diff. `lib.rs` marks the generated module
   `#[rustfmt::skip]` and allows its lints there and nowhere else.
4. **One Dart seam.** `lib/src/core.dart` declares the interface the app reads and re-exports the data types;
   `lib/src/frb_core.dart` is the one file that imports the generated object and calls `RustLib.init`. A test greps
   `lib/` for it. Pages, `data.dart` and actions see the interface only, so a fake, the web's fallback and the real core
   are interchangeable.
5. **Starting the core is `startup()`'s**, through `fespalier_frb`'s `initRustCore(loadCore)`, which reports one span
   and rethrows (so `splash.dart` shows the error and `retry` runs it again). FRB's `init` refuses a second run: do
   fallible work **before** it, and open a core that needs the container in `ready(container)` **after** it
   ([`fespalier-data`](../fespalier-data/SKILL.md), its `change-feeds.md` page, "Starting the core is the app's").
6. **The web returns first.** `if (kIsWeb) return unavailableOverrides();` is the first line of `startup()`, before
   anything that names the bindings, and the fallback core answers every call the way an unreachable server does.
7. **The core's provider throws until overridden** (`UnimplementedError` naming the override), like
   `fespalier_cratestack`'s seams, so a forgotten override fails loudly in a test and never reaches a device.
8. **A callback into Dart catches everything** and answers `null`: a throw in Dart panics the generated Rust code.
   It is called only from `async` Rust functions, never from a `#[frb(sync)]` one, which would deadlock. The timeout is
   Rust's (`tokio::time::timeout`), because only Rust knows a call is waiting.
9. **Errors are kinds and fixed sentences.** The core throws one error type whose `kind` decides what Dart does and
   whose message is the engine's own text, **never a server's** (it may land in telemetry or on a page).
10. **One subscription to the core's stream**, held by a `ChangeFeed`; pages watch topics. FRB 2.13 tells Rust nothing
    when Dart cancels a stream, so the forwarder ends at its next event or when the core is dropped.
11. **The FRB version is exact everywhere**: the Dart runtime, the hooks package (native assets), the Rust crate, the
    generated headers and the codegen. Nothing at compile time catches a mismatch: bindings generated from another
    `api/` than the library's fail at `RustLib.init`, which compares the two sides' `rustContentHash`.
12. **What only a device can show is written UNCHECKED** (the build per target, the library found by name, a keystore
    callback, cleartext rules, backgrounding mid-call) and gets a `human-test` issue, as frb-cose's
    [#271](https://github.com/fespalier/fespalier/issues/271) does.

[`references/bridge-surface.md`](references/bridge-surface.md) has the patterns for the surface: opaque handles, sync
and async functions, streams with a backlog, callbacks, errors.

## Building the core: Cargokit or native assets

FRB 2.13 builds the crate one of two ways. **Native assets** (Dart build hooks; `hook/build.dart` with
`flutter_rust_bridge_hooks`) is what frb-cose uses and what CI runs: every `flutter test`, `run` and `build` compiles
the core for the target, and a host test gets a real library. **Cargokit** (`rust_builder/`, a plugin package that hooks
Gradle, CocoaPods and CMake) is still FRB's default for `create`/`integrate`, works on older SDKs and can ship
precompiled binaries, but `flutter test` builds nothing with it. For a new fespalier app, take native assets.
[`references/build-integration.md`](references/build-integration.md) compares them and has the migration.

## CrateStack in the core

The core can be CrateStack's own generated **Rust client** (frb-cose: `include_client_schema!`, sealing every call as
COSE_Sign1), in which case it is a `CrateStackTransport` to `fespalier_cratestack` and the intents stay in Dart; or it can
run CrateStack's **embedded SQLite mode** (`include_embedded_schema!`) as the app's `LocalStore` or `SyncRunner`, which no
example builds yet. [`references/cratestack-embedded.md`](references/cratestack-embedded.md) has both, and what the
embedded mode does not give you.

## The web

A web build runs `hook/build.dart` and gets no code asset, and FRB's web backend (wasm) is not what frb-cose uses. So
the example's web build has **no core**: `startup()` returns an `UnavailableCore` (every call fails as `transport`,
`changes()` is empty, the journal is empty) and a transport over it, the pages disable what needs the core and say why,
and `just examples-web` checks those pages in Chromium. Keep `web: true` in `flutter_rust_bridge.yaml` so the generated
library still compiles for the web: the bindings are imported, never called.

## Tests

| Layer           | What runs                                                                                                              |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `rust/` engine  | `cargo fmt --check`, clippy `-D warnings`, `cargo test` (unit, and `tests/` against a server in process), `cargo deny` |
| Bindings        | the pinned codegen regenerates, then `git diff --exit-code` and no untracked file                                      |
| Dart, fakes     | widget tests through `pumpRouter` with a fake core: no library, no `RustLib.init`                                      |
| Dart, real core | `core_ffi_test.dart`: `RustLib.init(externalLibrary: ExternalLibrary.open(<path>))` against a stub                     |
| End to end      | `e2e_test.dart` starts the server binary an env variable names; a second variable makes it required                    |
| Boundary        | `bindings_boundary_test.dart` greps `lib/` for who imports the bindings                                                |

[`references/testing.md`](references/testing.md) has each one and the traps (the bare library name does not resolve
on a host; the first `flutter test` builds the core in release and takes minutes).

## What the other skills own

| The part                                                                                | Skill                                                                                    |
| --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `ChangeFeed`, topics, `ChangeCodec`, `ChangeBudget`, `initRustCore`, `FakeChangeSource` | [`fespalier-data`](../fespalier-data/SKILL.md) (its `change-feeds.md` page)              |
| `startup()`, `ready(container)`, `splash.dart`, `main: manual`                          | [`fespalier`](../fespalier/SKILL.md) (its `app-main.md` page)                            |
| A `CrateStackTransport`, the answer table, the error reader, idempotency                | [`fespalier-cratestack`](../fespalier-cratestack/SKILL.md) (its `embedded-mode.md` page) |
| Intents, `ref.serve`, `LocalStore`, `SyncRunner`, `autoSync`                            | [`fespalier-offline`](../fespalier-offline/SKILL.md)                                     |
| The device key the core calls back to sign (`fespalier_keypair`)                        | [`fespalier-guards`](../fespalier-guards/SKILL.md) (its `auth-device-sessions.md` page)  |
| `pumpRouter`, overrides in tests, the traps that hang a test                            | [`fespalier-testing`](../fespalier-testing/SKILL.md)                                     |
| The `fespalier.frb.*` spans and what they never carry                                   | [`fespalier-observability`](../fespalier-observability/SKILL.md)                         |

## Not built

- **No `fsp` support.** `fsp` knows nothing of `rust/`: no `fsp create` feature, no `fsp new` template, no task. Write
  the layout by hand from frb-cose; a `tasks:` entry for the codegen is yours.
- **No adapter.** `RustLib` is the app's generated class, so no package can call it; `initRustCore` takes it as an
  argument.
- **No FRB dependency in any fespalier package.** The bindings pin their own runtime exactly, and FRB 2.13 needs Dart
  3.9.2, above fespalier's 3.35.0 floor; `fespalier_frb` is a `Stream` and Riverpod.
- **No Rust core on the web**, no persistence in frb-cose's core, and no example of the embedded CrateStack mode or of
  Cargokit: what those pages say about them is from their own documentation, not a fespalier test.

## References

- [`references/layout.md`](references/layout.md): the layout, file by file, with each skeleton
- [`references/bridge-surface.md`](references/bridge-surface.md): designing `api/`: handles, sync and async, streams,
  callbacks, errors
- [`references/build-integration.md`](references/build-integration.md): Cargokit against Flutter native assets, and
  moving from one to the other
- [`references/cratestack-embedded.md`](references/cratestack-embedded.md): CrateStack in the core, as its generated
  client or its embedded SQLite store
- [`references/testing.md`](references/testing.md): the tests at each layer, and CI
