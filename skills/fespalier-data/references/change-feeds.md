# `fespalier_frb`: providers rebuilt by a Rust core's change stream

Since 0.13.0. A Rust core behind `flutter_rust_bridge` (or any core) answers calls and **says what changed** on a `Stream`. A
`data.dart` that reads the core is stale the moment the core says something changed, and nothing in fespalier knew: the
usual answers were a `Timer`, a `ref.listen` in every page, or an `invalidate` call in the code that happened to hold the
stream. `package:fespalier_frb` is the Riverpod-shaped answer: the stream is held **once**, a `topic` is a provider whose
value moves only on a matching event, and a `data.dart` that **watches** the topic is rebuilt exactly then. It changes no
generated code and adds no file kind, key or command; an app that does not depend on it pays nothing.

It has **no `flutter_rust_bridge` dependency, on purpose.** The generated bindings pin the FRB runtime exactly per app (FRB 2.13
needs Dart 3.9.2, above fespalier's Flutter 3.32 floor), and the generic part is a `Stream<E>`. Do not add one.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_frb:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_frb
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves the pair only at a release tag. `docs/data.md` has the annotated block.)

## Wire it

The core below is a stand-in for what flutter_rust_bridge generates: a class (or top-level functions) with the calls, and an
event type with a `Stream` of it.

```dart
// lib/core/core.dart
import 'package:fespalier/fespalier.dart';

/// What the Rust core says changed (in a real app, a mirror of the Rust enum).
sealed class CoreEvent {
  const CoreEvent();
}

final class OrderChanged extends CoreEvent {
  const OrderChanged(this.id);

  final int id;
}

final class CartCleared extends CoreEvent {
  const CartCleared();
}

/// The seam the app programs against; the generated bindings are behind it.
abstract class Core {
  Stream<CoreEvent> changes();

  Future<String> order(int id);
}

/// A stand-in for the generated bindings: the app's `RustLib.init()` and the object it opens.
abstract final class RustLib {
  static Future<void> init() async {}
}

class RustCore implements Core {
  @override
  Stream<CoreEvent> changes() => const Stream.empty();

  @override
  Future<String> order(int id) async => 'Order $id';
}

final coreProvider = Provider<Core>((ref) => RustCore());
```

```dart
// lib/core/changes.dart
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:my_app/core/core.dart';

/// The one subscription: opened by the first topic anyone watches, once per container, cancelled with it.
final changes = ChangeFeed<CoreEvent>(
  (ref) => ref.watch(coreProvider).changes(),
  name: 'core',
);

/// Watch `orderChanged(id)` to be rebuilt when order [id] changes, and on no other event.
final orderChanged = changes.topic<int>(
  (event, id) => event is OrderChanged && event.id == id,
);
```

```dart
// lib/app/orders/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/core/changes.dart';
import 'package:my_app/core/core.dart';

Future<String> data(Ref ref, {required int id}) {
  ref.watch(orderChanged(id)); // the watch is the invalidation: no listen, no timer
  return ref.read(coreProvider).order(id);
}
```

```dart
// lib/app/orders/$id/page.dart
import 'package:flutter/material.dart';

class OrderPage extends StatelessWidget {
  const OrderPage({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) => Text(data);
}
```

- **`watch` the topic, `read` the core.** The topic is what makes the provider depend on the event; the core is a plain read
  (a `watch` of `coreProvider` would rebuild on a restarted core, which is a different thing and sometimes wanted).
- **One subscription for N topics.** `changes.latest` is a keep-alive `StreamProvider<Change<CoreEvent>>`; every topic watches it. The
  function you pass to `ChangeFeed` runs **once per container** (a generated stream takes one listener). If it does
  `ref.watch(coreProvider)` and the core is restarted, the stream is opened again and the old one cancelled.
- **A topic moves only on a match.** Its per-key revision is an auto-dispose `Notifier<int>`; an event for another key
  rebuilds the revision but returns the same number, and Riverpod does not notify the dependents of an unchanged value. The
  first watch counts nothing: an event older than the watcher is history.
- **Equal events are still two changes.** Riverpod 3 drops a state equal to the last, so `latest` carries `Change(event, seq)`
  and `Change` is never `==`. Riverpod rebuilds lazily and hands a burst to a dependent a change at a time, so a burst can
  take a few rounds, but **no event is lost**: the feed keeps a log of the last 64 events of its subscription
  (`changeLogCapacity`) and a topic scans every event it missed (`[7, 42, 7]` rebuilds the watcher of 42; a paused page
  catches up on resume). A watcher that missed more than the log holds, or whose core was restarted, rebuilds anyway.
  Do not "fix" a burst with a debounce: a debounce is a timer.
- **A stream error** stays in `changes.latest` as an `AsyncError` (watch it for a "live updates stopped" banner); no topic
  rebuilds on it, and the next event works.
- **`changes.any`** is a topic of every event (an `int` that counts each event, a burst included), for a provider that depends on
  the whole core.
- **Cost.** Each watched key runs its matcher once per event. Tens or hundreds of keys: nothing. A core that emits thousands of
  events a second should emit coarser ones (a table, not a row) or use an `InvalidationTable`.
- **Hidden tabs.** A page in a hidden tab has its watchers paused by Riverpod and catches up when it is shown _(not checked on a
  device)_.

## When the app owns the subscription: `InvalidationTable`

An app that already receives the events in its own code (or will not edit its `data.dart` files) uses the pure form. It holds
no container, no `Ref`, no stream: a list of rules from an event to the providers it makes stale, applied with the
invalidation function you pass.

```dart
// lib/core/table.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:my_app/core/core.dart';

final ordersProvider = FutureProvider<List<String>>((ref) async => const []);
final cartProvider = FutureProvider<int>((ref) async => 0);
final orderProvider = FutureProvider.family<String, int>((ref, id) async => 'Order $id');

final table = InvalidationTable<CoreEvent>([
  InvalidationRule.on<OrderChanged, CoreEvent>((e) => [orderProvider(e.id), ordersProvider]),
  InvalidationRule.on<CartCleared, CoreEvent>((_) => [cartProvider]),
]);
```

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:my_app/core/changes.dart';
import 'package:my_app/core/core.dart';
import 'package:my_app/core/table.dart';

Future<void> startup() => initRustCore(RustLib.init);

/// The app's own subscription, held by the container: it dies with it.
Future<void> ready(ProviderContainer container) async {
  container.listen(changes.latest, (_, next) {
    final change = next.value;
    if (change != null) table.apply(change.event, container.invalidate);
  });
}
```

`apply` invalidates each provider **once** even if two rules list it, and returns how many it invalidated. `InvalidationRule.on<T, E>`
matches by type; the plain constructor takes a `bool Function(E)` and a `List<ProviderOrFamily> Function(E)`. A family
listed whole invalidates every member; `orderProvider(e.id)` only that one.

## Starting the core is the app's

`RustLib.init` is the generated bindings' and a generic package cannot name it, so there is **no adapter** and no
`beforeRun`: call it from `startup()` through `initRustCore` (above). It reports one span, `fespalier.frb.init`, ending `ok` or
`error` (the attribute `fespalier.frb.result`; not the error, its text or its stack trace), and rethrows the failure unchanged. `startup()` runs
before the router, behind `splash.dart`; a failure there is shown with `retry`, and a `beforeRun` failure would have no UI.

Which of `startup()` and `ready(container)` (since 0.12.0, [app-main](../../fespalier/references/app-main.md))?

| The core is...                                                                                                                                      | Put it in                                                     |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| started by `RustLib.init` alone, and read lazily by providers                                                                                       | `startup()`                                                   |
| opened on the container before the first route (a database at the app directory, a session to restore, `await container.read(coreProvider.future)`) | `RustLib.init` in `startup()`, the open in `ready(container)` |

A retry of `startup()` runs `init` again; a retry of `ready()` does not. FRB's `init` throws `StateError('Should not initialize flutter_rust_bridge twice')` the second time (check the message in your
version), so do any other fallible work in `startup()` **before** `initRustCore`, and everything after the init in `ready()`.
If that cannot be ordered, guard the retry with `if (!RustLib.instance.initialized) await initRustCore(RustLib.init);`; the
caveat is that `initialized` can already be true when the Rust initializer that `init` runs last is what failed, and the
guard then skips a core that never started. With `main: manual` you call
both yourself, in that order.

## Test it

`FakeChangeSource` (`package:fespalier_frb/testing.dart`) is a stream the test feeds: `emit`, `emitError`, `close`, `listenCount` (how
many times it was listened to: **1** for any number of topics), `cancelCount` and `hasListener`. `broadcast: false` makes it
single-subscription, like a generated stream. Override the core provider with a fake whose `changes()` is its stream.
`pumpRouter` does not run `startup()`, so a widget test needs no `RustLib.init` and no native library.

```dart
// test/orders_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:fespalier_frb/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/app/startup.dart';
import 'package:my_app/core/core.dart';
import 'package:my_app/core/table.dart';

class FakeCore implements Core {
  FakeCore(this.source);

  final FakeChangeSource<CoreEvent> source;
  final loads = <int, int>{};

  @override
  Stream<CoreEvent> changes() => source.stream;

  @override
  Future<String> order(int id) async {
    final n = loads[id] = (loads[id] ?? 0) + 1;
    return 'Order $id v$n';
  }
}

void main() {
  testWidgets('an event about order 42 loads order 42 again, others do not', (tester) async {
    final source = FakeChangeSource<CoreEvent>(broadcast: false);
    final core = FakeCore(source);
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders/42'),
      overrides: [coreProvider.overrideWithValue(core)],
    );
    expect(find.text('Order 42 v1'), findsOneWidget);

    source.emit(const OrderChanged(7));
    source.emit(const CartCleared());
    await tester.pumpAndSettle();
    expect(find.text('Order 42 v1'), findsOneWidget);

    source.emit(const OrderChanged(42));
    await tester.pumpAndSettle();
    expect(find.text('Order 42 v2'), findsOneWidget);

    source.emit(const OrderChanged(42)); // equal to the last event: still a change
    await tester.pumpAndSettle();
    expect(find.text('Order 42 v3'), findsOneWidget);
    expect(source.listenCount, 1);
  });

  test('the table invalidates what an event lists, once', () {
    final listed = <ProviderOrFamily>[];
    expect(table.apply(const OrderChanged(42), listed.add), 2);
    expect(listed, [orderProvider(42), ordersProvider]);
    expect(table.apply(const CartCleared(), (_) {}), 1);
  });

  test('initRustCore is one span, ok or error, and rethrows', () async {
    final sink = RecordingTelemetry();
    FespalierTelemetry.install(sink);
    addTearDown(() => FespalierTelemetry.install(null));
    await startup();
    await expectLater(initRustCore(() async => throw StateError('no library')), throwsStateError);
    expect(sink.log, [
      '#1 start custom fespalier.frb.init',
      '#1 end custom ok async fespalier.frb.result=ok',
      '#2 start custom fespalier.frb.init',
      startsWith('#2 end custom error async'),
    ]);
  });
}
```

- **A `ProviderContainer` of your own** (no `pumpRouter`) disposes on a zero-duration timer, and a provider derived from another
  recomputes on the same scheduler: `await container.pump()` (or `tester.pump()`) before you count rebuilds. Two events fed
  before the pump are **one** rebuild.
- **A test that feeds the fake after the container is disposed** gets nothing: disposal cancels the subscription
  (`source.hasListener` is false, `cancelCount` is 1).

## Not built

A `flutter_rust_bridge` dependency (the generated bindings own it); a typed event codec; a budget or a batching window for a
core that emits thousands of events a second (that would be a timer: emit coarser events, or apply an `InvalidationTable` yourself).
