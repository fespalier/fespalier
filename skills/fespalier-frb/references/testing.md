# Testing an app with a Rust core

Five layers, each cheap where the one below is slow. All of them run in [`examples/frb-cose`](../../../examples/frb-cose/README.md)
(its README, "Tests"); the general rules of a fespalier widget test are [`fespalier-testing`](../../fespalier-testing/SKILL.md)'s.

## 1. The engine, in Rust

In `rust/`: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`, `cargo build --locked`,
`cargo deny check`.

- **Unit tests beside the code** (`signer_tests.rs` next to `signer.rs`, through `#[cfg(test)] #[path = "..."] mod
tests;`). The callback is a plain Rust closure here, so a refused or slow signature is a test with a short timeout
  (`device_signer_within(..., Duration::from_millis(20))`).
- **Against a server in process** (`rust/tests/against_server.rs`): the server crate is a dev dependency by path, served
  on a local port, and the engine is driven through its public `core::` API. This is where a protocol is proven; Dart
  never re-checks it.
- **Contract tests** (`rust/tests/contracts.rs`): the ops the core accepts are the schema's.

`crate-type` must include `rlib`, or `tests/` cannot link the crate.

## 2. The bindings

The pinned codegen regenerates, and nothing may change:

```sh
flutter pub get    # the generator formats by the package's language version
flutter_rust_bridge_codegen generate
git diff --exit-code -- lib/src/rust rust/src/frb_generated.rs
git ls-files --others --exclude-standard -- lib/src/rust rust/src/frb_generated.rs   # must print nothing
```

The codegen expands the crate with `cargo-expand`, so pin that too (frb-cose: 1.0.127) and install both with
`cargo install --locked --version ...`. Check `flutter_rust_bridge_codegen --version` first and refuse another version.

## 3. The app, with a fake core

Every widget test overrides the core's provider with a fake that implements the seam (`lib/src/core.dart`), so it needs
no native library and no `RustLib.init`: `pumpRouter` does not run `startup()`. Build the overrides with the same
function `startup()` uses (`coreOverrides(core: fake, ...)`), so the wiring is tested too. The core's stream is a
`FakeChangeSource(broadcast: false)` (single-subscription, like a generated stream): its `listenCount` stays 1 however
many topics are watched ([change-feeds](../../fespalier-data/references/change-feeds.md#test-it)).

```dart
// sketch: test/support/fakes.dart
final class FakeCore implements Core {
  FakeCore(this.source);
  final FakeChangeSource<CoreEvent> source;
  final calls = <String>[];
  @override
  bool get available => true;
  @override
  Future<CoreAnswer> call({required String op, required String argsJson}) async {
    calls.add(op);
    return const CoreAnswer(status: 200, bodyJson: '[]');
  }
  @override
  Stream<CoreEvent> changes() => source.stream;
}
```

Test the **fallback core** the same way (`unavailableOverrides()`): the pages a web build shows are pages like any other.
And test `startup()`'s order without the library: frb-cose's boundary test reads `startup.dart` and checks the web return
comes before `initRustCore`.

## 4. The real core, on the host

`core_ffi_test.dart` opens the real core in `flutter test`, against a stub server written in Dart (`dart:io`), and checks
the core's side of the wire: the callback is called, the request leaves with its headers, an answer comes back.

**The bare library name does not resolve in a host test.** With native assets the hook puts the library in
`build/native_assets/<os>/` (`lib<crate>.so`, `lib<crate>.dylib`, `<crate>.dll`), and `RustLib.init()` does not look
there. Open it by path, once per isolate, and **throw** when it is missing (never skip: a missing file is a broken
build):

```dart
// sketch: test/support/host_core.dart
String hostCorePath() {
  final (folder, file) = switch (Platform.operatingSystem) {
    'linux' => ('linux', 'libmy_core.so'),
    'macos' => ('macos', 'libmy_core.dylib'),
    'windows' => ('windows', 'my_core.dll'),
    final other => throw UnsupportedError('no host core for $other'),
  };
  final path = File('build/native_assets/$folder/$file');
  if (!path.existsSync()) throw StateError('the core is not at ${path.absolute.path}: flutter test builds it');
  return path.absolute.path;
}

Future<void>? _loaded;
Future<void> initHostCore() => _loaded ??= RustLib.init(externalLibrary: ExternalLibrary.open(hostCorePath()));
```

With Cargokit nothing builds the core for `flutter test`: run `cargo build` in `rust/` first and open the file from
`rust/target/debug/` ([build-integration](build-integration.md)).

**The first run is slow**: the hook builds the core in release (frb-cose: 115 to 135 s cold, 4 to 20 s warm on a 4-vCPU
Linux machine). Every `flutter test` in the app pays it, including runs that only touch fakes.

## 5. End to end

`e2e_test.dart` starts the real server binary that an environment variable names (`FRB_COSE_SERVER_BIN`), with
`--exit-when-stdin-closes` so a killed run leaves no server, and drives the app over the real core. Without the variable
it **skips and says why**; with the second variable (`FSP_REQUIRE_FRB_COSE_SERVER=1`) a missing binary **fails**, so
the CI job that means to run it cannot pass by skipping. Name yours the same way.

## The boundary test

A test that reads `lib/` (comments left out) and pins who may name the bindings:

- only `lib/src/core.dart` (the data types) and `lib/src/frb_core.dart` (the object) import `lib/src/rust/`, however
  the import is spelled (relative, `./`, `../src/`, `package:`);
- only `frb_core.dart` names `RustLib` or the opaque object's `open(`;
- `startup()` returns the web fallback before `initRustCore`.

It is what keeps the seam a seam when the next person adds a page.

## CI

| Job             | Runs                                                                                                                                                       |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the app's tests | rustup with the channel read from `rust/rust-toolchain.toml`, a cache of `rust/target` and `.dart_tool/hooks_runner`, then `flutter test` (layers 3 and 4) |
| the core        | layer 1, and the server's own gates                                                                                                                        |
| the bindings    | layer 2, with the pinned codegen and `cargo-expand`                                                                                                        |
| end to end      | the server built, then layer 5 with the variable that makes it required                                                                                    |

All of frb-cose's run on Linux only. A build per platform, the library found by name on a device, a keystore callback,
cleartext and App Transport Security rules, and backgrounding mid-call are **UNCHECKED**: write them in the README and in a
`human-test` issue with the steps, as [#271](https://github.com/fespalier/fespalier/issues/271) does.
