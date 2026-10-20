# `fespalier_frb`: providers rebuilt by a Rust core's change stream

Since 0.13.0. A Rust core behind `flutter_rust_bridge` (or any core) answers calls and **says what changed** on a `Stream`. A
`data.dart` that reads the core is stale the moment the core says something changed, and nothing in fespalier knew: the
usual answers were a `Timer`, a `ref.listen` in every page, or an `invalidate` call in the code that happened to hold the
stream. `package:fespalier_frb` is the Riverpod-shaped answer: the stream is held **once**, a `topic` is a provider whose
value moves only on a matching event, and a `data.dart` that **watches** the topic is rebuilt exactly then. It changes no
generated code and adds no file kind, key or command; an app that does not depend on it pays nothing.

It has **no `flutter_rust_bridge` dependency, on purpose.** The generated bindings pin the FRB runtime exactly per app (FRB 2.13
needs Dart 3.9.2, which is Flutter 3.35.3, above fespalier's 3.35.0 floor), and the generic part is a `Stream<E>`. Do not add one.

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
- **A topic moves only on a match.** Its per-key revision is an auto-dispose `Notifier<int>` that watches the feed through a
  `select`, so an event for another key costs one call of the matcher and does not even rebuild the revision (since 0.21.0;
  before, it rebuilt and returned the same number). The first watch counts nothing: an event older than the watcher is history.
- **Equal events are still two changes.** Riverpod 3 drops a state equal to the last, so `latest` carries `Change(event, seq)`
  and `Change` is never `==`. Riverpod rebuilds lazily and may deliver a burst to a dependent in one rebuild or in several, but **no event is lost**: the feed keeps a log of the last 64 events of its subscription
  (`changeLogCapacity`) and a topic scans every event it missed (`[7, 42, 7]` rebuilds the watcher of 42; a paused page
  catches up on resume). A watcher that missed more than the log holds, or whose core was restarted, rebuilds anyway.
  Do not "fix" a burst with a debounce in a provider: a debounce is a timer. A busy key gets a `ChangeBudget` (below).
- **A stream error** stays in `changes.latest` as an `AsyncError` (watch it for a "live updates stopped" banner); no topic
  rebuilds on it, and the next event works. The function you gave `ChangeFeed` is not called again after a failure of its
  own either: `latest` does not retry (since 0.16.0; Riverpod's default would call it again, with a `Timer`).
- **`changes.any`** is a topic of every event (an `int` that counts each event, a burst included), for a provider that depends on
  the whole core.
- **Cost.** An event costs each watched key one matcher call (about a microsecond in a debug build) and a rebuild of the keys
  it concerns (since 0.21.0; before, every key was rebuilt by every event, which grew with the square of the keys). What a
  busy core costs the providers that reload, and the budget that bounds it, are in
  [A rebuild budget](#a-rebuild-budget-changebudget).
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
  before the pump are **one** rebuild while the feed keeps flowing; a key watched alone that both concern takes the second one
  turn later (Riverpod pauses the feed while its only watcher rebuilds), unless its topic has a budget.
- **A test that feeds the fake after the container is disposed** gets nothing: disposal cancels the subscription
  (`source.hasListener` is false, `cancelCount` is 1).

## A core that sends raw messages: `ChangeCodec`

Since 0.18.0. A typed flutter_rust_bridge stream needs none of this: FRB decodes the enum into the Dart classes, and a core
that sends a `Vec<CoreEvent>` per message is `changes().expand((batch) => batch)`. `ChangeCodec` is for a core that sends
**raw messages** (a `StreamSink<String>` of JSON, a `Vec<u8>` of CBOR, protobuf or bincode, a `ReceivePort` of plain
`dart:ffi`, a socket to a sidecar, or a core updated apart from the app) and decodes them in Dart, where one bad message
can be contained. It is a `StreamTransformer`: `ref.watch(core).rawChanges().transform(codec)` in the feed's `open` is the
whole change; `ChangeCodec.batch(split, decode)` takes a message that carries several events.

A message or batch item whose decoder throws is **skipped and never numbered**: no `Change.seq`, no topic moved, and the
feed goes on, with `latest` keeping its last change. Only an error of the source itself is an `AsyncError`. A decoder throws
`UnknownChange` for a variant a newer core added: it is skipped and counted apart from failures (`unknownCount` against
`errorCount`). `onSkipped(reason, stackTrace)` logs each skip, and what it throws becomes an `AsyncError` and drops the rest of
that message's events (a batch's items decoded before it, and those after it). Each subscription decodes on its own, so a codec
shared by a broadcast source that two containers watch counts one bad message twice, and calls `onSkipped` and makes the span
twice. With a telemetry sink, the 1st, 2nd, 4th, 8th... skip of each kind is one span, `fespalier.frb.decode`, a root span
(not under whatever was running), ending `skipped` (`unknown`) or `error`, with a count: constants only, never the message, a
name from the wire or the error's text. A decoded event reports nothing.

```dart
// lib/core/wire.dart
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:my_app/core/core.dart';

/// A core that sends its events as JSON text (a Rust `StreamSink<String>` of `serde_json::to_string`).
abstract class WireCore {
  Stream<String> events();
}

class RustWireCore implements WireCore {
  @override
  Stream<String> events() => const Stream.empty();
}

final wireCoreProvider = Provider<WireCore>((ref) => RustWireCore());

/// One event from its JSON object; a variant this app does not know is an UnknownChange.
CoreEvent eventFromJson(Map<String, Object?> json) => switch (json['type']) {
  'OrderChanged' => OrderChanged(json['id'] as int),
  'CartCleared' => const CartCleared(),
  _ => throw const UnknownChange(),
};

/// One event per message.
final wireCodec = ChangeCodec<String, CoreEvent>(
  (raw) => eventFromJson(jsonDecode(raw) as Map<String, Object?>),
);

/// Several events per message: an unknown or broken item is skipped alone.
final batchCodec = ChangeCodec.batch<String, Object?, CoreEvent>(
  (raw) => jsonDecode(raw) as List<Object?>,
  (item) => eventFromJson(item as Map<String, Object?>),
);

/// The feed over the raw messages: the codec is the only difference.
final wireChanges = ChangeFeed<CoreEvent>(
  (ref) => ref.watch(wireCoreProvider).events().transform(wireCodec),
  name: 'wire',
);

final wireOrderChanged = wireChanges.topic<int>(
  (event, id) => event is OrderChanged && event.id == id,
);
```

```dart
// test/wire_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/core/core.dart';
import 'package:my_app/core/wire.dart';

class FakeWireCore implements WireCore {
  final source = FakeChangeSource<String>(broadcast: false);

  @override
  Stream<String> events() => source.stream;
}

void main() {
  test('a bad or unknown message is skipped, and the feed goes on', () async {
    final core = FakeWireCore();
    final container = ProviderContainer(
      overrides: [wireCoreProvider.overrideWithValue(core)],
    );
    addTearDown(container.dispose);
    final revisions = <int>[];
    container.listen(wireOrderChanged(42), (_, next) => revisions.add(next));
    await container.pump();

    core.source.emit('{"type":"OrderChanged","id":42}');
    await container.pump();
    core.source.emit('not json');
    core.source.emit('{"type":"OrderArchived","id":42}'); // newer than this app
    await container.pump();
    core.source.emit('{"type":"OrderChanged","id":42}');
    await container.pump();

    expect(revisions, [1, 2]);
    expect(container.read(wireChanges.latest).value!.seq, 2);
    expect(core.source.listenCount, 1);
  });

  test('a batch is its events; an unknown item is skipped alone', () {
    final events = batchCodec.decode(
      '[{"type":"OrderChanged","id":7},{"type":"OrderArchived"},{"type":"CartCleared"}]',
    );
    expect(events, hasLength(2));
    expect(events.first, isA<OrderChanged>());
    expect(events.last, isA<CartCleared>());
  });
}
```

- The codecs are top-level, so their counts add up across a test file: assert on what `decode` returns, not on `unknownCount`
  or `errorCount`.
- A batch is a burst: a watcher rebuilds at most once for it while another watched key is not concerned, or something watches
  `changes.latest`, and one that no event of the batch concerns does not rebuild (since 0.21.0). A key watched alone takes the
  events of a batch one per turn and reloads once for each that concerns it, unless its topic has a budget (below).
- A heartbeat is a batch of none: `split` returns nothing, so there is no event and no skip.
- `ReceivePort` and protobuf are fragments, not built, the same as in `docs/data.md` (they need your generated classes and your
  FFI call):

```dart
// A protobuf message, with the generated `pb` library of your schema.
CoreEvent eventFromProto(Uint8List bytes) {
  final event = pb.Event.fromBuffer(bytes);
  return switch (event.whichKind()) {
    pb.Event_Kind.orderChanged => OrderChanged(event.orderChanged.id.toInt()), // an int64 is an Int64
    pb.Event_Kind.cartCleared => const CartCleared(),
    pb.Event_Kind.notSet => throw const UnknownChange(), // an unknown oneof member reads as notSet
  };
}

// A ReceivePort fed by plain dart:ffi (allo-isolate): the port is a stream of raw messages.
final port = ReceivePort('core changes');
ref.onDispose(port.close);
ref.watch(coreProvider).subscribe(port.sendPort.nativePort);
return port.transform(ChangeCodec<Object?, CoreEvent>((raw) => eventFromProto(raw as Uint8List)));
```

## A rebuild budget: `ChangeBudget`

Since 0.21.0. A key that matches more events than what watches it can reload gets a budget:
`topic(matches, budget: ChangeBudget(tick))` moves each key at most once between two ticks of `tick`, a provider the app fires.
Why, measured in the package's tests (a debug build, fake time):

- Riverpod runs a provider's rebuild after two zero-length timers, not once a frame, and `flutter_rust_bridge` delivers an event
  per event-loop turn, so a `data()` reloads once per event about its key: 5,000 a second are 5,000 reloads for 60 widget
  builds _(not checked on a device with a real core)_.
- A `data()` slower than the gap between its events never settles: 1,000 events a second and a 5 ms `data()` showed a loaded
  value in none of 60 frames.
- Riverpod 3 pauses `changes.latest` while every provider that watches it rebuilds, so a key watched alone takes a burst that
  concerns it one event per turn. With no topic watched at all, the stream is paused too and holds what the core sends; a
  shell banner that watches `changes.latest.select((v) => v.hasError)` keeps it flowing.

A key that has not moved since the last tick moves at once on the first event that concerns it; the next ones are held; the next
tick moves it once if anything was held. That move opens the next period: an event right after a tick that released a held change
is held for the tick after it, and only a tick that moved nothing lets the next event through at once.
Nothing is dropped (a held change waits for the next tick, however long the core stays quiet), a tick moves only the keys that
hold a change, and a held key does not rebuild, so the burst goes through in one turn. With a 16 ms tick, 5,000 events a second
are 61 reloads; with the slow `data()`, 40 of 60 frames show a loaded value (50 ms: 21, 100 ms: 11).

The package has no clock (`test/no_timers_test.dart`), so the tick is the app's: a `RefetchSignal` it fires from a timer of its
own, auto-dispose so that it is created by the first budgeted key watched and disposed with the last. Disposal alone does not stop
the timer while the page is hidden: Riverpod pauses the watchers of a page that an opaque route covers or of a tab that is not shown,
and a paused watcher keeps its provider alive, so a timer that is only cancelled in `onDispose` fires every 100 ms for a page
nobody sees (600 fires in a minute with the only budgeted key paused, measured with fake time). The recipe starts the timer in
`build`, stops it in `onCancel` and starts it again in `onResume`; a held change of a paused key waits for the page to be shown
again and for the next tick after that. One tick serves every budgeted topic. `changes.any` has no
budget: `changes.topic<Null>((_, _) => true, budget: ...)(null)` is a budgeted "anything changed" that counts moves.

```dart
// lib/core/budget.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:my_app/core/changes.dart';
import 'package:my_app/core/core.dart';

/// Fires every 100 ms while a budgeted key is watched and active: the app's timer, not the package's.
final changeTick = NotifierProvider.autoDispose<RefetchSignal, int>(ChangeTick.new);

class ChangeTick extends RefetchSignal {
  Timer? _timer;

  void _start() => _timer ??= Timer.periodic(const Duration(milliseconds: 100), (_) => fire());

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  int build() {
    _start();
    ref.onCancel(_stop); // every budgeted key is paused (a covered page, a hidden tab): no timer
    ref.onResume(_start);
    ref.onDispose(_stop);
    return 0;
  }
}

/// An order moves at most once per tick, however busy the core is.
final busyOrderChanged = changes.topic<int>(
  (event, id) => event is OrderChanged && event.id == id,
  budget: ChangeBudget(changeTick),
);
```

```dart
// test/budget_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/core/budget.dart';
import 'package:my_app/core/core.dart';

class FakeCore implements Core {
  FakeCore(this.source);

  final FakeChangeSource<CoreEvent> source;

  @override
  Stream<CoreEvent> changes() => source.stream;

  @override
  Future<String> order(int id) async => 'Order $id';
}

void main() {
  test('a busy order moves at once, then at most once per tick', () async {
    final source = FakeChangeSource<CoreEvent>(broadcast: false);
    final container = ProviderContainer(
      overrides: [
        coreProvider.overrideWithValue(FakeCore(source)),
        changeTick.overrideWith(RefetchSignal.new), // nothing fires it but the test
      ],
    );
    addTearDown(container.dispose);
    final moves = <int>[];
    container.listen(busyOrderChanged(42), (_, next) => moves.add(next));
    await container.pump();

    source.emit(const OrderChanged(42));
    await container.pump();
    expect(moves, [1]); // nothing moved since the start: at once

    for (var i = 0; i < 100; i++) {
      source.emit(const OrderChanged(42));
    }
    await container.pump();
    expect(moves, [1]); // held

    container.read(changeTick.notifier).fire();
    await container.pump();
    expect(moves, [1, 2]); // one move for the hundred
  });
}
```

- **A tick that never fires holds a change for ever.** In a test that is what you want (fire it by hand); in the app, the tick's
  timer runs while a budgeted key is watched and active, which is why it is auto-dispose and stops in `onCancel`.
- **Pick the period from the screen**: 100 ms is ten updates a second; a key with a slow `data()` wants a period longer than one
  load.

## Not built

A `flutter_rust_bridge` dependency (the generated bindings own it); a codec per format in the package (JSON is `jsonDecode`
and a `switch`; protobuf, CBOR and bincode would be dependencies, and their generated types are per app: the codec takes your
decoder); a provider that counts skips (`unknownCount`, `errorCount` and `onSkipped` are enough); a clock of the package's own
for `ChangeBudget` (a timer or a frame callback: the tick is the app's), and a budget on `changes.any`.
