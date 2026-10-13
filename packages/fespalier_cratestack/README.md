# fespalier_cratestack

Offline-first [CrateStack](https://cratestack.dev) clients for [fespalier](https://github.com/fespalier/fespalier)
(since 0.10.0): reads that say how current they are, mutations that wait for the network and are decided once, rows
a device edits and merges field by field, and the triggers that sync them. fespalier itself is unchanged: no `fsp`
change, no `fespalier:` key, and the same `app.g.dart`. It depends on no CrateStack package, starts no timer and
listens to nothing.

The long version is two pages: [CrateStack with fespalier](../../docs/cratestack.md) (wiring, examples, debug
messages) and [Offline-first](../../docs/offline-first.md) (the ideas, which do not depend on CrateStack). This page
is the short one.

## Install

Add it next to fespalier (and `fespalier_dio` if your client uses Dio), with the same `url` and the same `ref`: pub
resolves them to one package only if they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_dio:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: v0.15.0
  fespalier_cratestack:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_cratestack
      ref: v0.15.0
```

<!-- x-release-please-end -->

Needs Dart 3.8 and Flutter 3.32 or newer. It depends on `clock`, `dio` (`^5.7.0`, only `dio.dart` imports it) and
`hive_ce` (`^2.16.0`, only `hive.dart` imports it), all pure Dart.

## Four libraries

| Library                                                  | For                                | What is in it                                                                                                                                |
| -------------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_cratestack/fespalier_cratestack.dart` | everything that is not Dio or Hive | the transport seam, errors, `Served` and `ref.serve`, `LocalStore`, `ReadCache`, intents, owned rows and the merge, `SyncEngine`, `autoSync` |
| `package:fespalier_cratestack/dio.dart`                  | Dio                                | `ref.cancellable`, `CrateStackCancelInterceptor`, `CrateStackPortalInterceptor`, `DioFailures`                                               |
| `package:fespalier_cratestack/hive.dart`                 | a durable store                    | `HiveLocalStore`, a hive_ce box that never evicts                                                                                            |
| `package:fespalier_cratestack/testing.dart`              | tests                              | `FakeCrateStackTransport`, `FakeRowServer`, `ManualSyncTicker`, `crateStackTestOverrides`                                                    |

## Wire it

The generated client's types live in your app, so you write two small seams once, and override the providers in
`startup()`:

```dart
final class GeneratedTransport implements CrateStackTransport {
  GeneratedTransport(this.adapter);
  final CratestackRpcAdapter adapter; // from your generated client

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) => switch (call) {
    RpcCall(:final opId, :final input) =>
      adapter.call(opId, input, options: CratestackRpcCallOptions(idempotencyKey: idempotencyKey)),
    RestCall() => throw UnsupportedError('this app uses the RPC transport'),
  };
}

CrateStackFailure? readShopError(Object e) => e is CratestackRpcException
    ? CrateStackFailure.fromEnvelope(status: e.status, code: e.code, message: e.message, details: e.details)
    : null;

// startup()
[
  crateStackTransport.overrideWith((ref) => GeneratedTransport(ref.watch(shopAdapterProvider))),
  crateStackErrors.overrideWithValue(const CrateStackErrors([readShopError, DioFailures.read])),
  crateStackScope.overrideWith((ref) => ref.watch(authUserId)),      // whose data this is
  localStore.overrideWithValue(store),                               // await HiveLocalStore.open(directory: supportDir)
  readCache.overrideWithValue(ReadCache.storage(dataStorage, index: store)), // optional: reads on your dataCache storage
  reconnectSignal.overrideWith(ConnectivitySignal.new),             // fespalier_connectivity
  syncTicker.overrideWith(ForegroundTicker.new),                    // your own timer, see below
]
```

The root `layout.dart` does `ref.watch(autoSync)` once. A sign-out calls `ref.read(crateStackAccount).clear()` before
the session ends: it removes that account's intents, rows and saved reads.

## Read

```dart
// lib/app/orders/data.dart
FutureOr<Served<List<Order>>> data(Ref ref) => ref.serve(
  key: 'orders',
  codec: _codec,
  empty: () => const [],
  fetch: () {
    final client = ref.watch(shopClientProvider); // watch before, never inside cancellable
    return ref.cancellable(() => client.models.order.list());
  },
);
```

`Served<T>` is the value, where it came from (`network` or `local`), when the server last answered this read for
this account (`fetchedAt`) and whether that is older than `maxAge` (`stale`). Policies: `networkFirst` (default),
`cacheFirst`, `localOnly`, `serverOnly`. Only a connection failure falls back to the device; a refusal is the
answer. An empty list offline is an answer (`neverFetched`); a single row with nothing saved is
`CrateStackNoLocalData`. Keep `Freshness` in the same `data.dart`: it decides when the read runs again, `serve`
decides where the answer comes from. Do not combine it with `dataCache`.

## Write: intents

```dart
// lib/app/orders/action.dart
Future<IntentOutcome<Order>> cancel(Ref ref, {required CancelInput input}) => ref
    .read(intentQueue)
    .submit(
      RpcCall('cancelOrder', CancelOrderArgs(id: input.orderId, expectedVersion: input.expectedVersion).toWire()),
      subject: 'order:${input.orderId}',
      touches: const {'orders'},
      decode: (o) => OrderMapper.fromMap(o! as Map<String, Object?>),
    )
    .withCrateStackFieldErrors(ref);
```

The call (JSON-native: a `DateTime` throws, bytes would become a list) is saved, then sent once with the key `<id>#<attempt>`; `Accepted` only when the server said yes, `Queued`
when there was no answer (the next sync sends the same bytes under the same key). A refusal on the spot is thrown
and nothing is kept; behind an undecided intent of the same `subject` it is saved and `Queued` without being sent. The server must key its idempotency store by a verified principal, or a token refresh between attempts makes a replay a second run. In a drain a refusal is kept `failed` with its wire code only, a conflict is kept `conflict`,
a stored failure (`5xx`) moves to the next key. An intent never expires on the device, and a sign-out removes it.
The full table is in [the docs](../../docs/cratestack.md#5-actions).

## Owned rows

```dart
await ref.read(ownedRows).edit('notes', 'n1', {'title': 'Groceries'}); // stamped, saved, dirty
```

A field is the unit: each carries a hybrid-logical-clock stamp, two devices that edit different fields both keep
their edit, and for the same field the causally later stamp wins on both. A tombstone is a field. A read never
overwrites an unpushed edit; a row the server refuses is rolled back and reported with its code. You implement
`RowSync` over two procedures in your schema (CrateStack has no sync protocol of its own); `SyncEngine` does push,
then pull, then drain.

## Sync triggers

`autoSync` syncs on start, on `appResumeSignal`, on `reconnectSignal` and on `syncTicker`. The package never starts
a timer, so the periodic trigger is yours:

```dart
class ForegroundTicker extends RefetchSignal {
  @override
  int build() {
    final t = Timer.periodic(const Duration(minutes: 5), (_) => fire());
    ref.onDispose(t.cancel);
    return 0;
  }
}
```

Each exists for a reason: a device that never backgrounds and never loses signal would otherwise never push.

## Test it

```dart
final transport = FakeCrateStackTransport()..on('cancelOrder', (input) => {'id': 42});
final container = ProviderContainer(overrides: crateStackTestOverrides(transport: transport));
transport.loseAnswer('cancelOrder'); // the server runs it, the client hears nothing
// submit -> Queued; drain() -> a DrainReport with accepted == 1; transport.runs('cancelOrder') is 1
```

The fake transport keeps an idempotency store, so a replay under the same key does not run twice. Everything is a
`Future.value`: a `testWidgets` leaves no timer pending. Use `FakeConnectivity` from `fespalier_connectivity` for
the reconnect trigger.

## Rules

- **No timers, no listeners.** `test/no_timers_test.dart` greps `lib/` for timers, delays, `.listen(`, `DateTime.now()`
  and a seeded `Random`; the sync is started by a side `then`, and the clock is `package:clock`.
- **An intent is never evicted.** The durable store is not one of fespalier_storage's budgeted storages, which evict
  the entries written longest ago. (`ReadCache.storage(...)` is the place for those: a cache can be evicted.)
- **Only a connection failure reads from the device.** A refusal is the answer.
- **Never a success the server has not given.** `Queued` is not `Accepted`.
- **Nothing the server said is kept or sent.** An intent keeps the wire code, never the message; a rollback reports a
  code. No intent argument, row value, subject or server message goes to telemetry (there is no sync span yet).
- **Ids come from `Random.secure()`**, never from the clock or a path.
- **No CrateStack package.** If one is ever needed it is pinned by commit, never by a version tag:
  `cli/tests/versions.rs` reads every tag pin in this repository's packages as fespalier's own version.

## Not built

Signed intents (a re-confirmation or a device-bound proof on a queued call), paging helpers beyond the cursor loop,
a sync telemetry span, and a background isolate. See [Offline-first](../../docs/offline-first.md#limits).
