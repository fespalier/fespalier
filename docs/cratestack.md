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

**A Rust core that is the client** (since 0.21.1). The seams above are for a Dart client. When the network layer is a
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

The preset is the one that matters here. `--preset riverpod` writes a client on Dio (sections 3 and 4 below). With
`--preset fespalier` (merged in CrateStack in cratestack/cratestack#1206, in no release after 0.15.4, so the CLI comes
from a commit: `examples/cratestack` builds it at the one that also has `@authn`) the client sends through fespalier's [`HttpTransport`](transport.md) and links no Dio: its
`<prefix>TransportProvider` and `<prefix>BaseUriProvider` are the two seams the app overrides, typically with
`ref.watch(authTransport)`. [`examples/cratestack`](https://github.com/fespalier/fespalier/blob/main/examples/cratestack/README.md)
is the example with a generated client: that preset, a Rust server, device-signed sessions, and a script that generates the
client again in CI and compares. It also lists what the generated calls cannot do yet and what to do about each.

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
  be the type `data()` returns (`Served<List<Order>>`, or a `typedef` of it declared in your package since 0.21.0, or in a `path:` dependency since 0.22.0):
  `fsp` matches by type, through the typedefs of the files it reads.
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
- The same key with a different body is `422` `VALIDATION_ERROR` (`invalid_argument` over RPC) with a message starting
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

**Validation errors become form errors.** `withCrateStackFieldErrors(ref)` turns a `422` `VALIDATION_ERROR` (REST) or `invalid_argument` (RPC: CrateStack's RPC codes are gRPC-style; read as a field error since 0.21.0) into
fespalier's `FieldErrors`, like `withFieldErrors` in `fespalier_http` and `fespalier_dio` do. CrateStack documents the message
(`field 'email' is not a valid email address`) but no per-field structure for `details`, so the package reads
`details` when it is a map of field to message or a list of `{field|path, message}`, and falls back to the
message. That shape is an assumption; anything else is tolerated, not an error. `fieldName: (key) => ...` maps
the server's key to your form's field.

**Step-up (`@authn`, since 0.25.0).** A procedure can say how recently and how strongly the caller must have
authenticated: `@authn(maxAge: 300, amr: ["hwk"], acr: [...])` next to its `@allow` (cratestack/cratestack#1244, ADR
0022; in no CrateStack release yet). An unmet requirement is RFC 9470's step-up refusal: a `401` (RPC code
`unauthenticated`) whose envelope has `error: "insufficient_user_authentication"` and `details` (`max_age`,
`acr_values`, `amr`, `unmet`), and a `WWW-Authenticate: Bearer error="insufficient_user_authentication", ...` header,
**on REST and on RPC unary responses alike** (a batch frame carries the refusal in the frame only). The challenge's
scheme is `Bearer` whatever your provider, and over CBOR the body is not text, so a client reads the header. The session
acts on it before the generated client sees it ([Step-up authentication](auth.md#step-up-authentication)): an OpenID
Connect session re-authorizes the user once, a [device session](auth.md#device-signed-sessions-fespalier_sign_keypair)
signs the same request again with the user-present key, and the call is sent once more. What reaches the call is a
refusal that stands (a second one, a cancelled prompt, or work that may not ask: run a sync or a queue drain inside
`Authorizer.unattended`, since a generated call cannot set `Authorizer.stepUpAttribute`), typed by the generated
client as a `CratestackRpcException` whose `stepUp` is a `StepUpRequired`. The client's own `retryAfterStepUp` is not
needed for this: the session has retried the call once already, and a refusal that reaches it is the answer. The server's provider fills the facts (`auth_time`, `amr`,
`acr`) through CrateStack's principal contract; [`examples/cratestack`](https://github.com/fespalier/fespalier/blob/main/examples/cratestack/README.md)
maps a signature by the user-present key to `amr` `["user", "pop"]` and its time to `auth_time`, and declares
`@authn(amr: ["user"])` on `payOrder`. One server-side catch: CrateStack's idempotency layer keeps the 401 under the
call's `Idempotency-Key`, and the retry is the same request under the same key, so the example's store releases a key
whose answer is a 401.

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

### Subscriptions (`@@subscribe`)

A model with `@@subscribe` (and `@@emit(created, updated, deleted)`) has a server-sent event stream at
`GET /rpc/subscribe/<op id>`. Since 0.25.0 `crateStackEvents` reads it through your transport, as a
`LiveConnection<CrateStackModelEvent>` from [fespalier_stream](streaming.md), and the usual use is to sync when it says
something changed ([A push from the server](offline-first.md#a-push-from-the-server)):

```dart
// lib/server_changes.dart
final serverChanges = ChangeFeed<CrateStackModelEvent>.live(
  (ref, _) {
    // Who is signed in: signing in, out or as someone else replaces the connection.
    ref.watch(crateStackScope);
    return crateStackEvents(ref.watch(apiTransport), apiBase, 'model.Note.subscribe');
  },
  rules: LiveRules(reconnectOn: [reconnectSignal]),
  name: 'serverChanges',
);

// startup():
syncPushSignal.overrideWith((ref) => ref.watch(serverChanges.any)),
```

**`connect` must watch the account.** The request goes out under the session of the moment it is made. A feed that does
not watch who is signed in starts as a signed-out app (a `401`, which ends it with `ServerEventsRefused` and nothing
reopens it, so the app never hears the server) and, after a sign-out, keeps reading under the old session. With the
`ref.watch(crateStackScope)` above (or `authSession.select`, as in
[Sign-in and sign-out](streaming.md#sign-in-and-sign-out)), signing in replaces a refused feed with a new connection, and
a new account never reads the old one's. That rebuild starts with no resume point and, after an earlier open, is a gap,
so the app syncs once for the new account.

A topic of the same feed moves a page by model or by row (`serverChanges.topic<String>((e, model) => e.model ==
model)`), for a screen that reads through `ref.serve` rather than owned rows. `fespalier_cratestack` now depends on
`fespalier_stream`, at the same `ref`.

What CrateStack 0.15.4 sends, and what follows from it (measured against a 0.15.4 server):

- **Each change** is `event: message` with `data: {"id": n, "next": {"event_id", "model", "operation",
"occurred_at", "data"}}`. `CrateStackModelEvent` has the model, the operation (`Created`, `Updated`, `Deleted`), the
  `eventId` (a UUID, the same for every subscriber, which tells a duplicate after a reopen), `occurredAt` and
  `sequence` (the JSON `id`, from 1 on each connection). Its `toString` prints the model and the operation only. The
  row (`data`) is **not kept** unless you pass `keepData: true`: an event is a hint, and a change feed keeps its last
  64 events, so a row in each could hold megabytes. A message that does not decode is skipped and counted, never an
  error; `onSkipped` hears it with an error whose `source` is the raw message, row included, so log its type, not the
  error.
- **No event ID, so every reopen is a gap.** The server sends no `id:` field and ignores `Last-Event-ID`: a connection
  that opens again cannot ask for what it missed. A `ChangeFeed.live` moves every watched key (and `any`) at such a
  reopen, so the app syncs once more.
- **A subscriber that lags is dropped.** Past a buffer of 64 events (and whatever the socket holds), the server sends
  `event: error` with `{"code": "unavailable", "message": "subscription lagged"}` and ends the response.
  `crateStackEvents` drops that event; the connection opens again at once (a gap, so a sync).
- **No heartbeat, so a connection that died silently is not found.** A quiet model sends no byte, so `LiveRules.idle`
  would close a healthy subscription: leave it unset. Then nothing tells a connection that died without a word (a NAT
  that dropped it, a proxy that stalled) from a quiet one. A `reconnectOn` signal and the `streamTicker` act on a
  connection that is _waiting_ (and the ticker on an idle or paused one), never on one that looks open, so changes made
  while it is dead are missed until something replaces it ([Liveness](streaming.md#liveness)). What replaces it is a
  rebuild of the feed: make `connect` watch `appShowSignal` too, and each time the app is shown again after it was
  hidden the feed opens a new connection, which has no resume point and so is a gap, which is one sync. That costs a
  sync per show and makes a phone that comes back from the background current. Without it, the app's `syncTicker`,
  `appResumeSignal` and `reconnectSignal` still sync by themselves; only the push is blind.
- **`Accept` is required.** Without `Accept: text/event-stream` (or `*/*`) the server answers 406;
  `crateStackEvents` always sends it. A refusal (a 406, a 401 from your `AuthProvider`) ends the connection with
  `ServerEventsRefused`, and only a rebuild of the feed (the account in `connect`, above) opens it again.
- **No read policy on a subscription.** CrateStack 0.15.4 authenticates a subscriber through your `AuthProvider` and
  then checks neither the model's `@@allow("read", ...)` nor its row policy: an event, and the row in its `data`, goes
  to every subscriber, and **an anonymous caller gets every event unless your `AuthProvider` refuses it**. So treat an
  event as a hint that something changed, read the rows through the policy-checked API (a sync, a `ref.serve`), never
  render from `data`, and make sure your `AuthProvider` (or a layer in front of the router) refuses an anonymous
  subscriber.
- **A subscription is per model, not per account.** There is no filter on whose row changed, so an event reaches
  **every connected device of every user** that subscribes to the model, and each of them syncs (a request that
  pulls nothing of the writer's, since your procedures filter by account). The cost grows with the number of
  devices times the number of writes: bound it with a budget (next item), or filter in a layer in front of the router.
- **Your own push echoes back.** The server tells the device that wrote the row too, so one local edit is two syncs: the
  one that pushed it, then the one the echo starts (which pulls what the server just accepted). The
  [offline example](examples.md#offline) does exactly this.
- **Bound it with a budget.** `serverChanges.any` has none. A topic of the same feed with a
  [`ChangeBudget`](streaming.md#a-rebuild-budget-changebudget) moves at most once between two ticks of a signal your
  own timer fires, however many events arrive, and the first event after a quiet period still moves it at once:

  ```dart
  final syncPushTopic = serverChanges.topic<Object?>(
    (event, _) => true, // or: event.model == 'Note'
    budget: ChangeBudget(syncPushTick), // a RefetchSignal fired from your timer, every 5 s say
  );

  // startup():
  syncPushSignal.overrideWith((ref) => ref.watch(syncPushTopic(null))),
  ```

  Events held back are not dropped: the next tick moves the topic once for all of them, and that is one sync.

A device signature over the subscription's `GET` (an empty body, like any other request through a signing transport)
is expected to work and is UNCHECKED: the 0.15.4 example server has no model to subscribe to.

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
- **Resuming a subscription, or applying its events.** CrateStack 0.15.4 sends no event ID and applies no read policy
  to a subscription, so an event is never written to a row or a cache: it starts a sync (since 0.25.0), and a reopen is
  a gap that starts one too. A server that one day sends IDs and checks read policies could make both possible.
