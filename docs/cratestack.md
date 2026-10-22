# CrateStack with fespalier

`fespalier_cratestack` (since 0.10.0) puts a [CrateStack](https://cratestack.dev) client behind fespalier's
`data.dart` and `action.dart`, and makes it work offline: reads that say how current they are, mutations that
wait for the network, and rows a device edits and syncs. The idea behind it is in
[Offline-first](offline-first.md); this page is how to wire it.

Install and the short version: [`packages/fespalier_cratestack/README.md`](https://github.com/fespalier/fespalier/blob/main/packages/fespalier_cratestack/README.md).

## What it is, and what it is not

- **No `fsp` change.** You write `data.dart` and `action.dart` as always and call this package inside them.
- **No CrateStack package.** The package never imports CrateStack's Dart runtime. Your generated client
  reaches it through two small seams you write once (a transport and an error reader, below), so its
  pinned dependencies (`cratestack_cbor` pins `flutter_rust_bridge` exactly) stay yours.
- **No timers.** It starts no timer and listens to nothing. The one periodic trigger is a signal your app fires
  from its own timer.
- **Pre-1.0 upstream.** CrateStack is pre-1.0. This page was written against its `generate-dart` client and
  its documented behaviour; where something is an assumption it says so.

**A Rust core that is the client** (since 0.22.0). The seams above are for a Dart client. When the network layer is a
Rust core, CrateStack's own generated Rust client can be that core: [`examples/frb-cose`](examples.md#frb-cose) is the
generated client of its schema, on `cratestack-client` with its `cose` feature, behind flutter_rust_bridge, sealing every
call as `COSE_Sign1`. Its `CoreTransport` is the same `CrateStackTransport` over the core, so `ref.serve` and the intents
run unchanged, and the device key stays in Dart, which the core calls back to sign.

**CrateStack's Dart COSE.** At 0.15.3 CrateStack shipped no Dart COSE. At 0.15.4 its `cratestack_cbor` has a COSE module
with no ESP256 signer, so a device key still needs a sealer of its own ([`examples/cose`](examples.md#cose), a Dart one
checked against CrateStack's test vectors) or the Rust core ([`examples/frb-cose`](examples.md#frb-cose)).

## 1. Generate the client

```sh
cratestack generate-dart \
  --schema schema.cstack \
  --out packages/shop_client \
  --library-name shop_client \
  --preset riverpod \
  --run-build-runner
```

Commit the output as a path dependency of the app, and gate it in the app's CI with
`cratestack generate-dart ... --check`, so a schema change cannot leave it stale.

Use the **RPC transport**. Every procedure takes a per-call options object that carries the idempotency key,
and RPC errors are typed (`CratestackRpcException` with a status, a code and a message). REST works for
reads; a REST intent works too (`RestCall`) but REST has no typed error, so the classification below has
only the HTTP status to go on.

## 2. Wire it once, in `startup.dart`

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async {
  final dir = await getApplicationSupportDirectory();
  final store = await HiveLocalStore.open(directory: dir.path);
  final prefs = await PrefsDataStorage.open(); // null when shared preferences could not open
  return [
    // the generated client, on a Dio whose adapter is your transport chain (section 3)
    shopAdapterProvider.overrideWith((ref) => CratestackDioAdapter(dio: ref.watch(dio))),

    // the two seams
    crateStackTransport.overrideWith((ref) => GeneratedTransport(ref.watch(shopAdapterProvider))),
    crateStackErrors.overrideWithValue(
      CrateStackErrors([readShopError, (e) => TransportFailures.read(DioErrors.toTransport(e))]),
    ),

    // whose data it is, and where queued work lives
    crateStackScope.overrideWith((ref) => ref.watch(authUserId)),
    localStore.overrideWithValue(store),
    // optional: keep saved reads in the storage your dataCache already uses, with its key list in
    // the durable store, so a sign-out can wipe them and nothing evicts the list
    if (prefs != null) readCache.overrideWithValue(ReadCache.storage(prefs, index: store)),

    // the triggers
    reconnectSignal.overrideWith(ConnectivitySignal.new), // fespalier_connectivity
    syncTicker.overrideWith(ForegroundTicker.new),        // see "Triggers" in offline-first.md
  ];
}
```

The transport is the thin wrapper that satisfies `CrateStackTransport` over the generated adapter. The class
name `CratestackRpcAdapter` lives in your generated package, which is why this package cannot ship it:

```dart
final class GeneratedTransport implements CrateStackTransport {
  GeneratedTransport(this.adapter);
  final CratestackRpcAdapter adapter;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) => switch (call) {
    RpcCall(:final opId, :final input) => adapter.call(
      opId,
      input,
      options: CratestackRpcCallOptions(idempotencyKey: idempotencyKey),
    ),
    RestCall() => throw UnsupportedError('this app uses the RPC transport'),
  };
}
```

The error reader turns the generated exception into a classification. `CrateStackFailure.fromEnvelope` applies the
status and code table (section 5):

```dart
CrateStackFailure? readShopError(Object e) => e is CratestackRpcException
    ? CrateStackFailure.fromEnvelope(status: e.status, code: e.code, message: e.message, details: e.details)
    : null;
```

The root `layout.dart` watches `autoSync` once (it keeps the sync alive and can drive a banner), and a sign-out
calls `ref.read(crateStackAccount).clear()` before the session ends.

## 3. The Dio the client uses

```dart
// startup(): the chain AuthConfig sends through, the portal and the guard next to the network
final network = PortalTransport(WriteGuardTransport(HttpClientTransport(http.Client())));

final dio = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..httpClientAdapter = TransportAdapter(ref.watch(authTransport)); // SessionTransport over `network`
  WriteGuard.install(dio); // last: it goes first (fespalier_dio)
  ref.onDispose(dio.close);
  return dio;
});
```

Since 0.21.0 the generated client's Dio sends through a [transport chain](transport.md#the-interface): `TransportAdapter(chain)` (`fespalier_dio`) is its `httpClientAdapter`, so the session, the write guard and the telemetry decorators are the app's own, and one chain serves this client, the downloads and the images. `lib/dio.dart` and its two interceptors are gone from `fespalier_cratestack` (`package:fespalier_cratestack/dio.dart` until 0.20.0), and the package links neither Dio nor `package:http`.

`PortalTransport` (`fespalier_cratestack`) is what `CrateStackPortalInterceptor` was: it reads the `content-type` of every answer and, for `text/html`, throws a `TransportPortal`, which `TransportFailures.read` reads as offline. No transport treats a `200` as a failure, so without it a captive portal's page reaches the generated client, which cannot decode it, and no reader knows what it threw. Put it below the session, next to the network ([the order](transport.md#decorators-and-their-order)), so a portal's `401` page is offline and not a verdict that renews or ends the session; it passes the request and its attributes through unchanged.
What makes a page that went away stop its requests (`CrateStackCancelInterceptor` until 0.20.0) is `ref.cancellable` (section 4), which `TransportAdapter` honours.
`WriteGuard` (from `fespalier_dio`, see [HTTP clients](http.md)) keeps a retrier from
sending a write twice. The generated RPC reads are POSTs, so `WriteGuard` counts them as writes and a Dio retry
policy never repeats them. That is what you want: see section 6.

## 4. Reads in `data.dart`

```dart
// lib/app/orders/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:shop/api.dart'; // shopClientProvider (the generated client provider), Order, OrderMapper

/// Loaded again when a minute old and the app resumes or the network comes back.
const freshness = Freshness(
  staleTime: Duration(minutes: 1),
  refetchOnResume: true,
  refetchOnReconnect: true,
);

final _codec = ServedCodec<List<Order>>(
  toJson: (orders) => [for (final o in orders) o.toMap()],
  fromJson: (j) => [
    for (final m in j! as List<Object?>) OrderMapper.fromMap(m! as Map<String, Object?>),
  ],
);

/// The server's orders; offline, the last ones this account loaded here (Served says which, and when).
FutureOr<Served<List<Order>>> data(Ref ref) => ref.serve(
  key: 'orders',
  codec: _codec,
  empty: () => const [],
  fetch: () {
    final client = ref.watch(shopClientProvider);
    return ref.cancellable(() => client.models.order.list());
  },
);
```

```dart
// lib/app/orders/page.dart
class OrdersPage extends ConsumerWidget {
  const OrdersPage(this.orders, {super.key});
  final Served<List<Order>> orders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cancel = OrdersRoute.useCancel(ref);
    final waiting = ref.watch(pendingIntents(null)).value ?? const [];
    return Column(children: [
      if (orders.source == ServedFrom.local)
        Text(orders.neverFetched
            ? 'Offline: not loaded on this phone yet'
            : 'Offline copy, as of ${orders.fetchedAt}'),
      if (waiting.isNotEmpty) Text('${waiting.length} changes waiting to send'),
      for (final o in orders.value)
        ListTile(
          title: Text('Order ${o.id}: ${o.status}'),
          subtitle: waiting.any((i) => i.subject == 'order:${o.id}')
              ? const Text('Cancelling, will send when back online')
              : null,
          trailing: TextButton(
            onPressed: cancel.isPending
                ? null
                : () async {
                    final out = await cancel.call((orderId: o.id, expectedVersion: o.version));
                    if (!context.mounted || out == null) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(switch (out) {
                        Accepted() => 'Order cancelled',
                        Queued() => 'Saved. It will be sent when you are back online',
                      }),
                    ));
                  },
            child: const Text('Cancel'),
          ),
        ),
      if (cancel.hasError) Text('${cancel.state.error}'),
    ]);
  }
}
```

Things to know:

- **`Served<T>` is the value and how current it is.** `source` is `network` or `local`, `fetchedAt` is when the
  server last answered this read for this account, `stale` follows the `maxAge` you pass. The page parameter must
  be the type `data()` returns (`Served<List<Order>>`, or a `typedef` of it declared in your package since 0.21.0):
  `fsp` matches by type, through the typedefs of your own files.
- **`freshness` still decides _when_ a read runs again; `serve` decides _where the answer comes from_.** Do not
  combine `serve` with `dataCache`: `serve` keeps its own copy, per account.
- **`ref.cancellable` stops the request with the provider.** The generated options carry no cancel token, so the
  abort trigger travels in a zone value (`TransportZone`, in `fespalier_transport`) that `TransportAdapter` merges into
  the request's `abortTrigger` (a `CrateStackCancelInterceptor` picked up a cancel token from it until 0.20.0). The aborted
  request fails with a `TransportAborted`, which `TransportFailures.read` reads as `CrateStackCancelled`. Call it before the first `await`.
  The body must be only the client call: `ref.watch` and `ref.read` other providers _before_ it, as the example
  does. A provider that is built inside the body runs in the same zone, and its own requests would take this
  provider's token and be cancelled with it.
- **The default `invalidates` of an action reloads `data` after any outcome**, `Queued` included. That is
  harmless: the read stays as the server says, and the "cancelling" overlay comes from `pendingIntents`.

To read a generated provider with no offline fallback, select it as fespalier says
(`ProviderListenable<AsyncValue<Order>> data(Ref ref, {required int id}) => orderProvider(id)`).

The policies are `networkFirst` (default), `cacheFirst`, `localOnly` and `serverOnly`. Only `CrateStackOffline`
falls back to the device; a refusal is the answer. See [Offline-first](offline-first.md#reads).

## 5. Actions

```dart
// lib/app/orders/action.dart
typedef CancelInput = ({int orderId, int expectedVersion});

/// Cancelling is the server's decision: queued offline, sent with an idempotency key, decided once.
/// It never claims the order is cancelled before the server says so.
Future<IntentOutcome<Order>> cancel(Ref ref, {required CancelInput input}) => ref
    .read(intentQueue)
    .submit(
      RpcCall(
        'cancelOrder',
        CancelOrderArgs(id: input.orderId, expectedVersion: input.expectedVersion).toWire(),
      ),
      subject: 'order:${input.orderId}',
      touches: const {'orders'},
      decode: (o) => OrderMapper.fromMap(o! as Map<String, Object?>),
    )
    .withCrateStackFieldErrors(ref);
```

`submit` saves the call, sends it once, and returns either `Accepted` (the server said yes, with its answer) or
`Queued` (no answer; the next sync sends it again). A refusal on the spot is thrown, and nothing is kept.

- **A subject is ordered.** If an earlier intent for the same `subject` is undecided, the new one is saved and
  `Queued` without being sent: the next sync sends both, oldest first.
- **An error no reader knows** may have landed, like a lost answer, so the intent is kept under its key and the
  result is `Queued`, as a drain treats it. Add a reader to `crateStackErrors` to turn it into a decision.
- **The call must be JSON-native** (maps, lists, strings, numbers, booleans, `null`): it is stored as JSON. A
  `DateTime` in it throws before anything is saved, and bytes would silently become a list, which CBOR then sends as
  an array, not as bytes. Convert them in `toWire()`, as text.

**What the server's idempotency layer guarantees**
(from [cratestack.dev/guides/idempotency](https://cratestack.dev/guides/idempotency)):

- The `Idempotency-Key` header is opt-in and applies to mutations. The key lives in a namespace: the verified
  principal, else a hash of the `Authorization` header, else the peer address. With none of these the layer
  answers `412`.
- A replay of a finished request returns the stored answer with `Idempotency-Replayed: true`.
- A key that is still being answered gets `409` with `Retry-After: 1`. The package treats that as "same key,
  try later".
- The same key with a different body is `422` `VALIDATION_ERROR` with a message starting
  `idempotency_key_conflict`. That is a bug in the caller; the package never shows it as a form error.
- A TTL bounds the reservation. An intent never expires on the device, so the server's TTL is the only bound on
  "never".

**The server must namespace keys by a verified principal.** The key is stored per namespace: the verified
principal first, then (without one) a hash of the `Authorization` header, then the peer address. With the
`Authorization` fallback a token refresh between two attempts changes the namespace, so the replay of a call whose
answer was lost is a new request and runs the call a second time. `fespalier_auth` refreshes lazily and a `401`
keeps the same key, so this does happen. Configure the server's idempotency layer to use the verified principal
(CrateStack documents it as the first choice since 0.14.0), and do not queue a call whose double run matters
against a server that cannot.

The package builds the key as `<intent id>#<attempt>`, and sends the stored bytes every time. The answers it
recognises, row by row:

| The server answers                                                                  | Classified as               | The intent                              |
| ----------------------------------------------------------------------------------- | --------------------------- | --------------------------------------- |
| success                                                                             |                             | deleted, `touches` bumped               |
| no answer (network, timeout, a portal page, a `5xx` without CrateStack's envelope)  | `CrateStackOffline`         | `pending`, same key                     |
| `409` + `Retry-After`, or `409` `TRANSACTION_ABORTED` (the server did not store it) | `CrateStackInFlight`        | `pending`, same key                     |
| `401`                                                                               | `CrateStackUnauthenticated` | `pending`, same key                     |
| a `5xx` **in CrateStack's envelope** (`code` and `message`)                         | `CrateStackUnavailable`     | `pending`, **next key**, `failures + 1` |
| `422` `idempotency_key_conflict`                                                    | refused                     | `failed`                                |
| `409` without `Retry-After` and not `TRANSACTION_ABORTED`                           | `CrateStackConflict`        | `conflict` (the person resolves it)     |
| any other `4xx`                                                                     | `CrateStackRefused`         | `failed`, the wire code only            |

**A refused TLS certificate is not offline** (since 0.21.0). A `TransportUntrusted` (Dio's `badCertificate`) is
unclassified: a certificate that does not verify may be a captive portal or an attack, so a read behind `serve` serves no
saved copy for it and the error is rethrown, and a write is kept under its key as for any error no reader knows. Before
0.21.0 `DioFailures.read` read it as being offline. A `TransportBroken` is unclassified the same way.

**Only the server's own envelope moves the key** (since 0.16.0). A `5xx` that has CrateStack's envelope is a failure
the server said, and it may have stored it under the key, so the intent takes the next key. A `5xx` with no envelope
(a bare `500`, a proxy's `520`, a panic handler's plain text) is not the server's word: the write may have committed
before something in front of it answered, so it is `CrateStackOffline` and the intent keeps its key, which lets the
server answer the replay from what it stored. Before 0.16.0 a bare `500` moved the intent to the next key, and a
write that had committed ran a second time. A read behind `serve` now falls back to the saved copy on such an
answer, as it does on a `502`. A drain also reads each intent from the store again right before it sends it (since
0.16.0): an intent that a concurrent `submit` got accepted, that the person discarded or that a sign-out wiped while
the drain was busy with an earlier one is not sent.

**Validation errors become form errors.** `withCrateStackFieldErrors(ref)` turns a `422` `VALIDATION_ERROR` into
fespalier's `FieldErrors`, like `withFieldErrors` in `fespalier_http` and `fespalier_dio` do. CrateStack documents the message
(`field 'email' is not a valid email address`) but no per-field structure for `details`, so the package reads
`details` when it is a map of field to message or a list of `{field|path, message}`, and falls back to the
message. That shape is an assumption; anything else is tolerated, not an error. `fieldName: (key) => ...` maps
the server's key to your form's field.

## 6. Retries: one layer

Riverpod's data retry is the one retry layer for reads. A Dio retrier on top multiplies it ([Two retry layers
multiply](http.md)), and generated RPC reads are POSTs that `WriteGuard` refuses to repeat anyway. An
intent has its own, slower retry: the next sync. Nothing here sleeps or backs off with a timer.

## 7. Offline rows and sync

A device that edits rows while offline keeps them in `OwnedRows` and syncs them with a `RowSync` you write over
two procedures in your schema. CrateStack has no sync protocol of its own, so the push and pull belong to the
app. The merge rule is per-field last-writer-wins with a hybrid logical clock; the server side must use the same
rule, and write through the model layer so policies still apply. The details, with examples, are in
[Offline-first](offline-first.md#owned-rows).

## 8. Where CrateStack's embedded mode fits

CrateStack can also run inside the app: the same `.cstack` schema generates an embedded SQLite store
(`include_embedded_schema!` over `rusqlite`), reached from Flutter through FFI or `flutter_rust_bridge`
([cratestack.dev/guides/offline-first-sqlite](https://cratestack.dev/guides/offline-first-sqlite)).

**It fits as the durable store.** An app with a Rust crate on the embedded mode can implement `LocalStore` (a key
and value table) over its own generated functions, or read typed embedded tables directly in `data.dart` (watch
`crateStackRevision` for the tag, so a sync rebuilds the read). The same schema drives the server and the device,
so local rows have the server's shapes.

**It fits as a whole sync core.** An app whose Rust core already pushes, pulls and drains implements `SyncRunner`
and keeps `autoSync`, the triggers, `Served` and `IntentOutcome` for the Dart side. It skips `SyncEngine`.

**It does not fit as:**

- **A dependency of this package.** `flutter_rust_bridge` versions have to match across an app, and the bindings
  are generated by the app. The package stays pure Dart.
- **A sync engine.** There is none: the embedded mode documents no built-in sync, and `@@audit` and `@@emit` do
  nothing there.
- **The source of truth for decisions.** Policies are parsed but not enforced in the embedded mode, so the client
  is untrusted: every decision stays an intent that the server makes.
- **Flutter web.** The embedded wasm build needs OPFS in a dedicated worker, which Flutter's main isolate is not.
  On the web use `InMemoryLocalStore`, or `HiveLocalStore` on IndexedDB.
- **A synchronous first frame.** FFI calls are asynchronous in Dart, so a read backed by the embedded store is one
  `loading.dart` frame. The in-memory and Hive stores keep their reads synchronous.

## 9. Test it

```dart
final transport = FakeCrateStackTransport()
  ..on('cancelOrder', (input) => {'id': 42, 'status': 'cancelled'});
final container = ProviderContainer(
  overrides: crateStackTestOverrides(transport: transport),
);

transport.offline = true;
final out = await container.read(intentQueue).submit(/* ... */);
expect(out, isA<Queued<Order>>());

transport.offline = false;
await container.read(intentQueue).drain();
expect(transport.runs('cancelOrder'), 1);
```

`FakeCrateStackTransport` plays the server's idempotency layer: a replay under the same key returns the stored
answer and does not run twice, a reused key with another body answers `422`, `loseAnswer('op')` runs the call and
drops the answer, `refuse(...)` scripts a refusal. All answers are `Future.value`s: no timers, so a `testWidgets`
that uses them leaves nothing pending. `ManualSyncTicker`, `FakeRowServer` and `crateStackTestOverrides` are in
`package:fespalier_cratestack/testing.dart`. For the reconnect trigger use `FakeConnectivity` from
`fespalier_connectivity`. More in [Offline-first](offline-first.md#testing-offline).

## 10. Debug messages

| You see                                                                      | It means                                                         | Do this                                                                                           |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `UnimplementedError: fespalier_cratestack: override crateStackTransport ...` | An intent or a sync ran with no transport                        | Override `crateStackTransport` in `startup()` (section 2)                                         |
| `StateError: fespalier_cratestack: crateStackScope is null ...`              | Someone called `submit` or `OwnedRows` while signed out          | Override `crateStackScope`, and keep calls that must work signed out (a sign-in) out of the queue |
| `CrateStackNoLocalData` in `error.dart`                                      | A single-row read had no answer and nothing stored               | Show it with a retry; or pass `empty` if the read is a list                                       |
| `ArgumentError ... serve needs a fetch`                                      | `ref.serve` with a policy other than `localOnly` and no `fetch:` | Pass `fetch:`                                                                                     |
| An intent stuck `failed` with a code                                         | The server refused it                                            | Show the code, then `intentQueue.discard(id)`; the message is never stored                        |
| An intent stuck `conflict`                                                   | The server answered `409` without `Retry-After`                  | Let the person resolve it, then `discard` and submit again                                        |
| A queued intent never sends                                                  | No trigger is running                                            | Watch `autoSync` in the root `layout.dart`; check `crateStackScope` is the account that queued it |
| `fespalier_cratestack: ... an error no reader knows` (debug line)            | A client threw something no reader classifies                    | Add a reader to `crateStackErrors` for it                                                         |

## 11. Not built

- **Signed intents** (a re-confirmation, a device-bound proof of possession on a queued call). The intent is the
  stored call; a proof tied to a moment cannot be replayed from a queue. Signing **each attempt** at send time is
  another thing, and works: a `CrateStackTransport` that seals the call with a device key when `send` runs, so an
  intent's retries are new messages over the same payload under the same key. [`examples/cose`](https://github.com/fespalier/fespalier/blob/main/examples/cose/README.md)
  does it with COSE_Sign1, against a CrateStack server that verifies every request and seals every answer.
- **Paging helpers** for pulls beyond the cursor loop of `RowSync`.
- **Sync telemetry spans.** A data read through `serve` and an action that calls `submit` already run inside
  fespalier's data and action spans. A sync span is planned as a `TelemetryOp.custom` operation (since 0.11.0) named
  `fespalier.cratestack.sync`, an additive change to the telemetry conventions with no new `TelemetryOp` value; nothing from an intent, a row, a subject or a server message will ever be sent.
- **A background isolate.** Sync runs in the app's isolate while the app is open; a background sync is the app's.
