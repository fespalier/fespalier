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
  ([`forms-and-optimistic.md`](forms-and-optimistic.md)), never actions, even with a `Ref` (that is
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
  no loading state), a `FutureOr<T>` one returns what the function returned. A
  `Stream` is an error, and so is a bare `Future`.

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
