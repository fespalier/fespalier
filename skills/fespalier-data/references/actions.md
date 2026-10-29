# `action.dart`: typed writes

Since 0.5.0 (`Kind::Action` in `cli/src/scan.rs`, the runtime in
`packages/fespalier/lib/src/action.dart`). `data.dart` is what a route reads;
`action.dart` is what it **writes**: a submit, a save, a delete. It sits beside a
`page.dart` (or, in a page-less folder, beside the `layout.dart` of a section) and
takes the same segments and query parameters as a `data.dart`, plus the value being
written, `input`. fespalier generates a provider with pending and error state, a
one-shot helper and a hook, and after a success it invalidates the data the write
made stale.

The samples below share a tiny backend, an order page that reads an order and a
refund page that writes one.

```dart
// lib/orders.dart
import 'package:fespalier/fespalier.dart';

class Order {
  const Order(this.id, this.status);

  final int id;
  final String status;
}

class RefundInput {
  const RefundInput(this.amount);

  final int amount;
}

class Refund {
  const Refund(this.amount);

  final int amount;
}

class OrdersApi {
  final _refunded = <int, int>{};

  Future<Order> order(int id) async =>
      Order(id, _refunded.containsKey(id) ? 'refunded ${_refunded[id]}' : 'paid');

  Future<Refund> refund(int id, RefundInput input) async {
    if (input.amount <= 0) throw ArgumentError('amount must be positive');
    _refunded[id] = (_refunded[id] ?? 0) + input.amount;
    return Refund(input.amount);
  }
}

final apiProvider = Provider<OrdersApi>((ref) => OrdersApi());
```

```dart
// lib/app/orders/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/orders.dart';

Future<Order> data(Ref ref, {required int id}) => ref.read(apiProvider).order(id);
```

```dart
// lib/app/orders/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/orders.dart';

class OrderPage extends StatelessWidget {
  const OrderPage({super.key, required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Order ${order.id}: ${order.status}'),
      TextButton(
        onPressed: () => RefundRoute(id: order.id).go(context),
        child: const Text('Refund'),
      ),
    ],
  );
}
```

## The file

```dart
// lib/app/orders/$id/refund/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/orders.dart';

// What a success makes stale: the order page above this one (see below).
const invalidates = [OrderRoute];

Future<Refund> action(Ref ref, {required int id, required RefundInput input}) =>
    ref.read(apiProvider).refund(id, input);
```

```dart
// lib/app/orders/$id/refund/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/orders.dart';

class RefundPage extends HookConsumerWidget {
  const RefundPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refund = RefundRoute.useAction(ref, id: id);
    return Column(
      children: [
        FilledButton(
          onPressed: refund.isPending ? null : () => refund.call(const RefundInput(10)),
          child: const Text('Refund 10'),
        ),
        if (refund.isPending) const Text('Refunding...'),
        if (refund.hasError) Text('Failed: ${refund.state.error}'),
        if (refund.state.value case final done?) Text('Refunded ${done.amount}'),
      ],
    );
  }
}
```

- **Which functions are actions.** Every public top-level function whose first parameter
  is a positional `Ref`, **except the companions** (since 0.8.1): `form`, `validate` and
  `optimistic` beside `action`, or `approveForm`, `approveValidate` and `approveOptimistic`
  beside `approve`, are the form, the validation and the optimistic patch of that action
  ([`forms.md`](forms.md) for `form()`, since 0.11.0 the `fespalier_forms` package;
  [`optimistic.md`](optimistic.md) for the other two), never actions, even with a `Ref` (that is
  an error). An app on 0.7.0 that had an _action_ called `form` beside `action` must rename it. A function called `action` is always one, so a missing `Ref`
  is reported on it. Private functions and helpers that take no `Ref` are ignored. A
  file with none is an error.
- **Parameters.** After the `Ref`: **named** segments and query parameters, bound
  like `data()`'s (same names, same types, same errors, and a query parameter is
  optional and nullable), and `input`: **named, `required`, typed**, of any type. A
  type declared in `action.dart` or imported there is found the way a typed
  `extra`'s is (`fespalier-routing`, `typed-routes-and-extra.md`), so `submit` is
  typed. Any other parameter is an error.
- **Return type**: spelled out, `Future<T>`, `FutureOr<T>` or `T` (`Future<void>`
  too). **A sync action stays sync** (`submit` returns the value, no async gap,
  no loading state), a `FutureOr<T>` one returns what the function returned. A bare
  `Future` is an error. Since 0.25.0 a `Stream<T>` is a
  [streaming action](#streaming-actions-a-stream) (until 0.24.0 it was an error), and a
  bare `Stream` is an error too.

## What is generated

On `RefundRoute` (a `package:my_app/app.g.dart` member each; **static**, because an
instance member would have to name `Refund`, which the generated file can't):

| Member                                     | What it is                                                                                                            |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `RefundRoute.action(1)`                    | The provider (a `NotifierProvider` family), keyed by the keys. State: `AsyncValue<Refund?>`                           |
| `RefundRoute.submit(ref, id: 1, input: x)` | Runs it once: the `Future<Refund>`, **throws** what the action threw                                                  |
| `RefundRoute.useAction(ref, id: 1)`        | For `build`: a handle with `state`, `isPending`, `hasError`, `fieldErrors` (since 0.8.1), `reset()` and `call(input)` |

A function not called `action` names its members after itself: `approve` gives
`approveAction(keys)`, `approve(ref, ...)` and `useApprove(ref, ...)`. A section's
members are on its handle: `TeamsTeamIdSection.addMember(ref, teamId: 'acme', input:
'carol')`. A section with no `data.dart` still gets a handle for its actions
(`ShopSection`). A helper named like another member, a segment or query parameter of
the route, or another action's helper is an error.

- **State.** `AsyncData(null)` is **idle**; then `AsyncLoading`; then `AsyncError`
  or `AsyncData` of the result. Each key has its own. An `autoDispose` provider,
  kept alive for as long as a run is in flight.
- **`handle.call(input)` never throws**: it completes with the result, or with
  `null` when the action failed (the error is in `state`), so
  `onPressed: () => refund.call(input)` can't leave an unhandled error behind.
  **`submit` throws**, for code that wants to handle it (and the error is in `state`
  too). Neither navigates: do it after the `await`, behind `if (context.mounted)`.
- **No automatic retry, ever.** Riverpod's `retry` (the app's `ProviderScope(retry:)`)
  is for providers that fail while building, and an action's failure is not that.
  Running it again is the user's call. A failed write invalidates nothing.
- **Concurrency.** A second `call` while one is pending runs too: the state follows
  the last one started, and each success invalidates. Disable the button while
  `isPending` when a double write is wrong.
- **A page that goes away** (or the container) during a pending write doesn't throw:
  the state is only written while the provider is alive, and the write still
  completes and still refreshes the data.
- **`useAction` is a hook by name only**: it needs a `WidgetRef`, so it works in any
  `ConsumerWidget`, a `HookConsumerWidget` included.

## What a success invalidates

- **By default:** the route's own `data.dart` and the [section](sections.md) data
  above it (the set `AppRoutes.dataAt` lists), for the action's keys. A route with no
  data and no section above it invalidates nothing, which is why the sample above lists the
  order page's route.
- **`const invalidates = [...]` replaces that set.** The elements are the names of
  typed routes and section handles (`RefundRoute`, `OrderRoute`, `TeamsTeamIdSection`),
  not providers: providers aren't `const`. `const invalidates = <Object>[];` invalidates
  nothing. For a provider of your own, call `ref.invalidate(...)` in the action
  (it has a `ref`).
- **The action must take the keys of what it invalidates**, with the same types: the
  order's `data.dart` takes `int id`, and the action takes `id`. A route whose data is keyed
  by a query parameter (`String? q`) needs the action to take it. Otherwise it is an
  error that says so (see `fespalier-troubleshooting`).

## Streaming actions: a `Stream`

Since 0.25.0 (`packages/fespalier/lib/src/stream_action.dart`). An `action.dart`
function that returns `Stream<T>` is a write whose answer comes in pieces: a text a
model writes word by word, the progress of an export. Its state follows each item, the
user can stop it, and a page that goes away stops it.

```dart
// lib/exports.dart
import 'package:fespalier/fespalier.dart';

class ExportApi {
  /// The percentage done, as the server reports it.
  Stream<int> export(int id, String format) => Stream.fromIterable([25, 50, 100]);
}

final exportApiProvider = Provider<ExportApi>((ref) => ExportApi());
```

```dart
// lib/app/orders/$id/export/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/exports.dart';

/// Run first: a format the server does not know never starts the stream.
FieldErrors? validate(String input) =>
    input == 'csv' ? null : const FieldErrors({'format': 'Only csv for now'});

Stream<int> action(Ref ref, {required int id, required String input}) =>
    ref.read(exportApiProvider).export(id, input);
```

```dart
// lib/app/orders/$id/export/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class ExportPage extends HookConsumerWidget {
  const ExportPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final export = ExportRoute.useAction(ref, id: id);
    return Column(
      children: [
        if (export.isPending)
          TextButton(onPressed: export.cancel, child: const Text('Stop'))
        else
          FilledButton(
            onPressed: () => export.call('csv'),
            child: const Text('Export'),
          ),
        if (export.value case final percent?) Text('$percent%'),
        if (export.state case StreamFailed(:final error)) Text('Failed: $error'),
        if (export.state is StreamCancelled<int>) const Text('Stopped'),
      ],
    );
  }
}
```

- **The state** is a sealed `StreamActionState<T>`, not an `AsyncValue`: `StreamIdle`,
  `StreamRunning`, then `StreamDone`, `StreamFailed` (`error`, `stackTrace`) or
  `StreamCancelled`. Each has `latest` (the last item of the run, null before the
  first) and `count`. Every item is a new state, so the page rebuilds on each.
- **The members** are an action's: `ExportRoute.action(1)` (a `streamActionFamily`;
  `streamActionProvider` with no keys), `ExportRoute.submit(ref, id: 1, input: 'csv')`
  (a `Future` of the last item; throws what the stream threw) and
  `ExportRoute.useAction(ref, id: 1)`, a `StreamActionHandle` with `state`, `value`,
  `isPending`, `hasError`, `fieldErrors`, `call(input)` (`null` on a failure, never
  throws), `cancel()` and `reset()`.
- **`validate()` runs first**; the last run wins (a new `call` stops the one in
  progress, which ends cancelled).
- **Lifetime.** A run started from the hook lives while the page watches it: when the
  page goes away the subscription is cancelled, and the request under it with it.
  `submit` holds the provider alive until the stream ends, like a `Future` action; from
  a container, `call(input, hold: true)` does the same.
- **Invalidation** happens when the stream ends, and when a run is stopped after at least
  one item; never after a failure, and not for a run stopped because its page went
  away. Never retried.
- **Not built**: a `form()`, `const steps` or `optimistic()` beside it is an error.
- **Telemetry**: one action span per run, `fespalier.action.result` `ok`, `error` or
  `cancelled`, and `fespalier.action.items`, the count (never the items). No timer, and no
  listener but the stream's own subscription.

```dart
// test/export_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/exports.dart';

void main() {
  test('an export streams its progress to the end', () async {
    final container = ProviderContainer(
      overrides: [exportApiProvider.overrideWithValue(ExportApi())],
    );
    addTearDown(container.dispose);
    final states = <StreamActionState<int>>[];
    container.listen(ExportRoute.action(1), (_, next) => states.add(next));

    final last = await container.read(ExportRoute.action(1).notifier).call('csv');

    expect(last, 100);
    expect([for (final s in states) s.latest], [null, 25, 50, 100, 100]);
    expect(states.last, isA<StreamDone<int>>());
  });
}
```

To hold a stream mid-run in a test, return a `StreamController`'s stream from a fake
and add items by hand; `pump()` after each.

## Testing it

An action works without a widget, through its provider: that is the cheap test of what a
write does to the data.

```dart
// test/refund_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/orders.dart';

void main() {
  test('a refund makes the order reload', () async {
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(OrdersApi())],
    );
    addTearDown(container.dispose);
    // A page that watches it, as the order page does.
    container.listen(OrderRoute.data(1), (_, _) {});
    expect((await container.read(OrderRoute.data(1).future)).status, 'paid');

    final refund = await container
        .read(RefundRoute.action(1).notifier)
        .call(const RefundInput(10));

    expect(refund.amount, 10);
    expect(container.read(RefundRoute.action(1)).value?.amount, 10);
    expect(
      (await container.read(OrderRoute.data(1).future)).status,
      'refunded 10',
    );
  });

  testWidgets('the form shows the result of the write', (tester) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders/1/refund'),
      overrides: [apiProvider.overrideWithValue(OrdersApi())],
    );
    await tester.tap(find.text('Refund 10'));
    await tester.pumpAndSettle();
    expect(find.text('Refunded 10'), findsOneWidget);
  });
}
```

To look at the pending state, hold the fake backend on a `Completer` and `pump()`; no
timer is needed (`fespalier-testing`).

## Things that go wrong

- **The page didn't refresh.** The route has no `data.dart` of its own and the data
  that is stale belongs to another route: list it in `invalidates` (the sample
  above). With `invalidates` present, the default set is gone: list the route's own
  too.
- **`invalidates` doesn't compile.** Elements are `Type` literals of generated
  classes, so `action.dart` imports `app.g.dart`. A provider isn't one: invalidate it
  inside the action.
- **A `StateError` from an action.** It names the provider it can't invalidate;
  it should not happen with generated code, so report it.
- **`submit` throws `FieldErrors` without calling the server** (since 0.8.1) when a
  `validate()` beside the action refuses the input; `handle.call` returns `null` and the
  `FieldErrors` is in `state` and `handle.fieldErrors`.
- **Double submissions.** Not prevented by the library: disable the button while
  `isPending`.
- **After an `await`, the widget may be gone.** Check `context.mounted` before
  navigating or showing a snackbar.
