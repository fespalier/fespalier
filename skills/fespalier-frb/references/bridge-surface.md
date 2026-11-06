# Designing the bridge surface (`rust/src/api/`)

What FRB 2.13 generates from `api/` decides how much of the app can stay plain Dart. These are the patterns
[`examples/frb-cose`](../../../examples/frb-cose/README.md) uses (`rust/src/api/core.rs`), and why.

## Types that cross

- **Structs with public fields** become immutable Dart classes with `==` (`CoreConfig`, `CoreAnswer`, `JournalEntry`).
  Bytes are `Vec<u8>` (`Uint8List` in Dart); numbers that fit are `u16`, `u32`, `Option<_>` for absent.
- **Fieldless enums** become Dart enums (`CoreErrorKind`, `CoreEventKind`, `JournalOutcome`). **An enum with data
  becomes a `freezed` class**, which needs `build_runner: true` and `freezed` in the app: put the data in a struct
  next to a fieldless `kind` instead (`CoreEvent { kind: CoreEventKind, op: String }`).
- **One opaque handle** for everything stateful: a `pub struct` whose fields are private (`NotesCore { core: Arc<Core> }`).
  Dart holds a reference it cannot look into; its methods are the API. Keep the engine behind an `Arc` so a spawned task
  (a stream forwarder) can hold it too.
- **No engine type crosses.** Each `api` type has a `From<engine::X>` impl in the same file; the engine never imports
  `api`. A change in the engine is then never a regeneration unless the surface changes.
- **JSON for open-ended data.** frb-cose passes arguments and bodies as `String` JSON (`args_json`, `body_json`): the
  shapes belong to the server's schema, and Dart already has the codec (`fespalier_cratestack`'s calls take
  `Map<String, Object?>`). A typed struct per op is the alternative when the set is small and stable.

## Functions

| Rust                                                        | Dart                                 | Use it for                               |
| ----------------------------------------------------------- | ------------------------------------ | ---------------------------------------- |
| `pub fn open(...) -> Result<Self, CoreError>` on the handle | `static Future<NotesCore> open(...)` | building the engine (FRB makes it async) |
| `pub async fn call(&self, ...) -> Result<T, CoreError>`     | `Future<T> call(...)`                | anything that waits: I/O, a callback     |
| `#[frb(sync)] pub fn status(&self) -> T`                    | `T status()`                         | a read of memory that never waits        |
| `pub async fn changes(&self, sink: StreamSink<E>)`          | `Stream<E> changes()`                | events                                   |

- **A `#[frb(sync)]` function runs on Dart's thread.** It must never block, never wait on a lock another call holds
  across an `await`, and **never call a Dart callback**: the callback needs the very thread it is blocking, so it
  deadlocks. frb-cose's sync functions read the journal and the status and nothing else.
- **A sync call in `build()` is fine; an async one is a `data.dart`.** A synchronous status read can be a `Provider`
  that a page watches; an async call is the body of a `data()` or an action, so `loading.dart` and `error.dart` apply.
  FFI calls are asynchronous in Dart, so a page backed by an async core call has one loading frame.
- **`Result<T, E>`** throws `E` in Dart. Make `E` a struct that FRB marks as an exception (`CoreError implements
FrbException` in the generated Dart).

## Errors

```rust
pub enum CoreErrorKind { Unsigned, Unverified, Seal, Transport, BadInput, Registration }

pub struct CoreError {
    pub kind: CoreErrorKind,  // what Dart decides on
    pub status: Option<u16>,  // when the server answered
    pub message: String,      // the engine's own sentence, never a server's text
}
```

- The **kind** is the contract: the Dart side maps it once (frb-cose's `CoreTransport` turns it into a
  `CrateStackFailure`) and the pages never read the message.
- The **message** comes from the engine's fixed `Display` texts (`rust/src/core/error.rs`). A server's body, a URL with
  a query, an argument or a key never goes in it: it can end up in a log, telemetry or a page.
- Say, per kind, **whether anything was sent** (`BadInput` and `Seal`: nothing was; `Transport`: maybe). Offline code
  needs to know whether a write may have landed.

## Streams

```rust
pub async fn changes(&self, sink: StreamSink<CoreEvent>) {
    let (backlog, mut events) = self.core.subscribe(); // the last N events, and a broadcast receiver
    flutter_rust_bridge::spawn(async move {
        for event in backlog {
            if sink.add(event.into()).is_err() { return; }
        }
        loop {
            match events.recv().await {
                Ok(event) => if sink.add(event.into()).is_err() { break; },
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });
}
```

- **Async, so it runs on FRB's runtime**, where `spawn` has a reactor; the body itself awaits nothing.
- **A backlog** (frb-cose keeps 64 events): a listener that starts just after a call still sees it. `ChangeFeed` logs
  the last 64 too, so a topic that rebuilds misses nothing.
- **No cancel signal.** FRB 2.13 does not tell Rust that Dart cancelled the stream: the forwarder finds out at its next
  `sink.add`, or ends when the core is dropped. So one subscription, never one per page: that is what `ChangeFeed`
  holds ([change-feeds](../../fespalier-data/references/change-feeds.md)).
- **Typed events** need no decoder. A core that sends raw messages (`StreamSink<String>` of JSON, `Vec<u8>` of CBOR, one
  schema for several shells) decodes in Dart with `ChangeCodec`, which skips a bad message instead of ending the stream.
- **An event says what changed, not the new value.** The page reads the value again through the core; the event is the
  invalidation.

## Callbacks into Dart

```rust
pub fn open(
    config: CoreConfig,
    sign: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
) -> Result<NotesCore, CoreError>
```

Dart sees `FutureOr<Uint8List?> Function(Uint8List)`. Three rules:

1. **The Dart function catches everything** and answers `null` (or another "no" the type allows): a throw in Dart panics
   the generated Rust code.
2. **Called only from async Rust**, never from a `#[frb(sync)]` function (deadlock, above).
3. **Rust holds the timeout** (`tokio::time::timeout(SIGN_TIMEOUT, sign(bytes))`, 10 s in frb-cose): a user may
   background the app while a keystore prompt is up, and no answer must mean "nothing sent".

Pass the least: frb-cose sends the bytes to sign and gets the signature; the private key never crosses. A callback is
how a hardware key, a biometric prompt or a platform API reaches the core without the core depending on a plugin.

## Changing the surface

1. Edit `api/` (and the engine), never `frb_generated.rs` or `lib/src/rust/`.
2. Run the pinned codegen (`flutter_rust_bridge_codegen generate`, after `flutter pub get`), and commit both sides.
3. Change `lib/src/core.dart`'s interface and re-exports, the fake in `test/support/`, and `frb_core.dart`.
4. Run the bindings check, then the Dart and Rust tests ([testing](testing.md)).

Upgrading FRB is the same, plus every pin ([`SKILL.md`](../SKILL.md#the-rules), rule 11) and the generated headers
(`// @generated by flutter_rust_bridge@ 2.13.0`, `codegenVersion`), in one change.
