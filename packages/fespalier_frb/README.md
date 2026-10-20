# fespalier_frb

A Rust core's change stream for [fespalier](https://github.com/fespalier/fespalier) (since 0.13.0): the stream of "what
changed" that a core behind flutter_rust_bridge (or any other core) exposes, held by Riverpod in **one subscription**, and
providers that rebuild exactly when an event that concerns them arrives. It is a `Stream<E>` and Riverpod: **no
`flutter_rust_bridge` dependency** (the generated bindings pin their own runtime exactly, and FRB 2.13 needs a newer Dart than
fespalier's floor), no listener, no timer.

The docs cover all of it: [A Rust core's changes](https://github.com/fespalier/fespalier/blob/main/docs/data.md#a-rust-cores-changes-fespalier_frb)
(the feed, topics, the table, starting the core, testing). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.20.0
  fespalier_frb:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_frb
      ref: v0.20.0
```

<!-- x-release-please-end -->

## Wire it

```dart
// lib/core/changes.dart: the core's stream as a provider, and a topic per kind of change
final changes = ChangeFeed<CoreEvent>((ref) => ref.watch(coreProvider).changes());
final orderChanged = changes.topic<int>((event, id) => event is OrderChanged && event.id == id);

// lib/app/orders/$id/data.dart: watching the topic is the invalidation
Future<Order> data(Ref ref, {required int id}) {
  ref.watch(orderChanged(id));
  return ref.read(coreProvider).order(id);
}

// lib/app/startup.dart: starting the core is the app's (it names the generated RustLib)
Future<void> startup() => initRustCore(RustLib.init);
```

- `ChangeFeed.latest` is the one subscription (never auto-disposed, cancelled with the container); `topic(key)` moves only on a
  matching event (none of a burst is lost: the feed logs the last 64); `any` counts every event.
- `InvalidationTable` is the pure form, for an app that owns its subscription: `table.apply(event, container.invalidate)`.
- `ChangeCodec` (since 0.18.0) decodes a core that sends raw messages (JSON, bytes, a batch per message) in `open`: `(ref) => core.rawChanges().transform(codec)`. A message or item that does not decode, or whose decoder throws `UnknownChange` (a variant a newer core added), is skipped, counted and never numbered, and the feed goes on; `fespalier.frb.decode` reports it with constants and a count, never its text.
- `ChangeBudget` (since 0.21.0) holds a busy key to one move per tick of a provider the app fires (`topic(matches, budget: ChangeBudget(changeTick))`): a key that has not moved since the last tick moves at once on its first event, the next ones wait for the next tick, and nothing is dropped. Since 0.21.0 an event costs a key it does not concern one matcher call and no rebuild.
- `initRustCore` reports `fespalier.frb.init` (`ok` or `error`; not the error, its text or its stack trace) and rethrows, so `startup()` shows
  `splash.dart`'s error and can retry.
- `package:fespalier_frb/testing.dart` has `FakeChangeSource`, a stream the test feeds.

The package starts no timer and listens to nothing (`test/no_timers_test.dart`).
