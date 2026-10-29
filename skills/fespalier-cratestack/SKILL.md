---
name: fespalier-cratestack
description: "Wiring a CrateStack backend into a fespalier app with fespalier_cratestack (since 0.10.0) — the generate-dart client, the two seams the app writes (a CrateStackTransport over the generated RPC adapter, an error reader with CrateStackFailure.fromEnvelope), the startup() overrides, the transport chain under the generated Dio (PortalTransport, WriteGuardTransport and a TransportAdapter on its httpClientAdapter, since 0.21.0), ref.cancellable in data.dart, TransportFailures.read composed with DioErrors.toTransport, actions as intents with withCrateStackFieldErrors, the server's idempotency contract (keys namespaced by a verified principal) and the answer table, one retry layer, where the embedded SQLite mode fits, a Rust core that is CrateStack's client behind flutter_rust_bridge (since 0.21.1), a subscription (@@subscribe) read with crateStackEvents that makes autoSync sync by push, with its caveats (no event ID, no heartbeat, no read policy, since 0.25.0), and the package's debug messages. Load before connecting a CrateStack client to data.dart or action.dart, configuring its Dio or transport, or when a CrateStack call runs twice, is cancelled with another page, or an override error names crateStackTransport."
---

# fespalier-cratestack

> **Verified against fespalier `589cf391` (2026-10-08), release v0.13.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

**Since 0.10.0.** `package:fespalier_cratestack` puts a [CrateStack](https://cratestack.dev) client behind
`data.dart` and `action.dart` and makes it work offline. The ideas (reads that say how current they are, intents, owned
rows, sync) are [`fespalier-offline`](../fespalier-offline/SKILL.md) and the API is its; this skill is the **wiring**.

- **No `fsp` change**: no file kind, key or command, and the same `app.g.dart`. You write `data.dart` and `action.dart`
  as always and call the package inside them. It has **no `fespalier_adapter.dart`**, so `adapters:` cannot list it:
  it goes in `startup()`.
- **No CrateStack package dependency.** It never imports CrateStack's Dart runtime (`cratestack_cbor` pins
  `flutter_rust_bridge` exactly, which would be yours to resolve): your generated client reaches it through **two small
  seams you write once**, a transport and an error reader.
- **No timers, no listeners.** The one periodic trigger is a signal your app fires from its own timer.
- **CrateStack is pre-1.0.** The package was written against its `generate-dart` client and its documented behaviour;
  where something is an assumption, this skill says so.

## Install

```yaml
# pubspec.yaml: the same url and the same ref for all of them, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_dio: # TransportAdapter and DioErrors, if the generated client uses Dio
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_dio
      ref: <the same tag>
  fespalier_http: # HttpClientTransport, the end of the chain that reaches the network (or DioTransport from fespalier_dio)
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_http
      ref: <the same tag>
  fespalier_cratestack:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_cratestack
      ref: <the same tag>
```

(A fragment: pub resolves them only at a release tag that contains the packages, 0.10.0 or later; never write `ref: v…`
in these pages, where `cli/tests/versions.rs` reads it as fespalier's own version. The package's
[install block](https://github.com/fespalier/fespalier/blob/main/packages/fespalier_cratestack/README.md#install) is the
one release-please keeps current.) Dart 3.9, Flutter 3.35.

| Library                                                  | For                         | What is in it                                                                                                                                                                                                               |
| -------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `package:fespalier_cratestack/fespalier_cratestack.dart` | everything that is not Hive | the transport seam, errors, `Served` and `ref.serve`, `LocalStore`, `ReadCache`, intents, owned rows, `SyncEngine`, `autoSync`, and the HTTP pieces since 0.21.0: `ref.cancellable`, `PortalTransport`, `TransportFailures` |
| `package:fespalier_cratestack/hive.dart`                 | a durable store             | `HiveLocalStore`, a hive_ce box that never evicts                                                                                                                                                                           |
| `package:fespalier_cratestack/testing.dart`              | tests                       | `FakeCrateStackTransport`, `FakeRowServer`, `ManualSyncTicker`, `crateStackTestOverrides`                                                                                                                                   |

**Until 0.20.0** there was a fourth library, `package:fespalier_cratestack/dio.dart` (`ref.cancellable`,
`CrateStackCancelInterceptor`, `CrateStackPortalInterceptor`, `DioFailures`). It is **gone, not deprecated**: the package
links neither Dio nor `package:http` any more (`test/no_http_test.dart`), and each piece is a transport piece in the main
library (below). Delete the import; `ref.cancellable` moved with its name unchanged.

## 1. Generate the client

```sh
cratestack generate-dart --schema schema.cstack --out packages/shop_client --library-name shop_client \
  --preset riverpod --run-build-runner
```

Commit the output as a path dependency of the app and gate it in CI with `cratestack generate-dart ... --check`, so a
schema change cannot leave it stale. **Use the RPC transport**: every procedure takes a per-call options object that
carries the idempotency key, and RPC errors are typed (`CratestackRpcException`: status, code, message). REST works for
reads and for a `RestCall` intent, but REST has no typed error, so the classification has only the HTTP status to go on.

**`--preset fespalier`** (CrateStack's cratestack/cratestack#1206, merged and in no release after 0.15.4, so the CLI is built
from that commit) writes the same Riverpod client **with no Dio**: it sends through fespalier's `HttpTransport`, and the app
overrides `<prefix>TransportProvider` (typically `ref.watch(authTransport)`) and `<prefix>BaseUriProvider`; the adapter
provider defaults to the HTTP adapter over them. The pubspec pins `fespalier_transport` by git (`--fespalier-ref`; a commit
until fespalier 0.21.0 is released, overridden with the checkout inside this repository). Things the generated calls cannot do
yet, with what to do: a call carries no attributes for a signer (put a header on it and turn it into `TransportRequest.attributes`
in a decorator above the session); a generated exception wraps the transport's failure as its `cause`
(read the cause with `TransportFailures.read`). `examples/cratestack` does all of it.

## 2. The two seams

The generated types (`CratestackRpcAdapter`, `CratestackRpcCallOptions`, `CratestackRpcException`) live in **your**
generated package, which is why the package cannot ship these. Verbatim from the docs, as fragments (they cannot compile
without that package):

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

CrateStackFailure? readShopError(Object e) => e is CratestackRpcException
    ? CrateStackFailure.fromEnvelope(status: e.status, code: e.code, message: e.message, details: e.details)
    : null;
```

The same shape, built here against an **app-side stand-in** for the adapter's call so the `switch (call)` is checked:

```dart
// lib/shop_transport.dart
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// A stand-in for the generated adapter's call: your CratestackRpcAdapter.call has this shape, with its options object.
typedef RpcCaller = Future<Object?> Function(String opId, Object? input, {String? idempotencyKey});

final class ShopTransport implements CrateStackTransport {
  ShopTransport(this._call);

  final RpcCaller _call;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) => switch (call) {
    RpcCall(:final opId, :final input) => _call(opId, input, idempotencyKey: idempotencyKey),
    RestCall() => throw UnsupportedError('this app uses the RPC transport'),
  };
}
```

`CrateStackErrors([readShopError, (e) => TransportFailures.read(DioErrors.toTransport(e))])` runs the readers in order, **the app's reader first** (a
`CrateStackFailure` passes through as itself; anything unknown is `null` and is rethrown unchanged by whoever asked).
`CrateStackFailure.fromEnvelope` applies the status and code table (`fespalier-offline`,
[`fespalier-offline`](../fespalier-offline/SKILL.md) (its `intents.md` page)). `TransportFailures.read` is the last reader
(`DioFailures.read` until 0.20.0): it reads a `TransportFailure` or a `TransportStatusError` and knows no Dio type, which is
why a Dio client wraps it in `DioErrors.toTransport` (`fespalier_dio`), the function that turns a `DioException` back into
the failure its transport chain threw, or into a `TransportStatusError` for a 4xx or a 5xx. What each failure means:
`TransportUnsent`, `TransportTimedOut` and `TransportPortal` are `CrateStackOffline`, `TransportAborted` is
`CrateStackCancelled`, and `TransportBroken` and `TransportUntrusted` (a certificate that does not verify may be a captive
portal or an attack) are `null`, unknown. A `TransportStatusError` goes through `CrateStackFailure.fromResponse` by its
status and body, after the app's own reader had its turn.

## 3. `startup()`, the transport under the Dio and the root layout

The full, compiled wiring is [`references/wiring.md`](references/wiring.md). The overrides, in short:

- `shopAdapterProvider` (your generated client's provider) on a Dio you configure, `crateStackTransport` over it, and
  `crateStackErrors` with `[readShopError, (e) => TransportFailures.read(DioErrors.toTransport(e))]` (a top-level function
  keeps the `CrateStackErrors` `const`);
- `crateStackScope.overrideWith((ref) => ref.watch(authUserId))` (whose data it is: `fespalier_auth`) and
  `localStore.overrideWithValue(await HiveLocalStore.open(directory: ...))` (where queued work lives);
- optionally `readCache` on the storage your `dataCache` already uses, `reconnectSignal.overrideWith(ConnectivitySignal.new)`
  and `syncTicker.overrideWith(<your ticker>)`.

**The Dio sends through a transport chain (since 0.21.0).** The generated client keeps its own Dio, and you point that
Dio's `httpClientAdapter` at `TransportAdapter(chain)` (`fespalier_dio`); the chain is where the CrateStack pieces sit
([`docs/transport.md`](https://github.com/fespalier/fespalier/blob/main/docs/transport.md#decorators-and-their-order) has
the general order):

```dart
// lib/dio.dart
import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:http/http.dart' as http;

/// The chain next to the network: a portal's page is an error, and a write is marked as one.
final apiTransport = Provider<HttpTransport>((ref) {
  final network = http.Client();
  ref.onDispose(network.close);
  return PortalTransport(WriteGuardTransport(HttpClientTransport(network)));
});

final dio = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'))
    ..httpClientAdapter = TransportAdapter(ref.watch(apiTransport));
  WriteGuard.install(dio); // last: it goes first (fespalier_dio)
  ref.onDispose(dio.close);
  return dio;
});
```

```yaml
# pubspec.yaml dependencies
  dio: ^5.7.0
  http: ^1.5.0
```

- **`PortalTransport`** (it replaces `CrateStackPortalInterceptor`) throws a `TransportPortal` for a `text/html` answer,
  and `TransportFailures.read` reads that as **offline**: no transport treats a `200` as a failure, so without it a
  captive portal's page reaches the generated client, which cannot decode it, and no reader knows what it threw. It
  drains the page and keeps nothing of it.
- **The session goes in the chain, not in the Dio.** With `fespalier_auth`, put `SessionTransport(inner, ref.watch(authorizer))`
  around the chain above (or hand the chain to `AuthConfig.transport` and use `authTransport`): `SessionInterceptor` is
  gone (0.21.0). A signature or a token is then made again for every send, a replay after a 401 included.
- **`WriteGuard`** (the Dio's first interceptor) keeps a retrier from sending a write twice, and `WriteGuardTransport` marks
  a write for a `RetryClient` that sits above a `TransportClient`. The generated RPC reads are **POSTs**, so both count them as
  writes and a Dio retry policy never repeats them. That is what you want (section 6).
- **The cancel is in the adapter.** `TransportAdapter` merges Dio's cancel with the abort trigger of the zone
  `ref.cancellable` set (section 4); `CrateStackCancelInterceptor` is gone.
- The root `layout.dart` does `ref.watch(autoSync)` once (a sample is in `fespalier-offline`), and a sign-out calls
  `ref.read(crateStackAccount).clear()` **before** the session ends (`fespalier-guards`,
  [`auth-package.md`](../fespalier-guards/SKILL.md) (its `auth-package.md` page)).

## 4. Reads: `data.dart` with `ref.cancellable`

```dart
// lib/shop_client.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/dio.dart';

/// A STAND-IN for your generated package (shop_client): its client has these shapes, over the Dio of dio.dart.
class Order {
  const Order(this.id, this.status, this.version);

  factory Order.fromMap(Map<String, Object?> map) =>
      Order(map['id']! as int, map['status']! as String, map['version']! as int);

  final int id;
  final String status;
  final int version;

  Map<String, Object?> toMap() => {'id': id, 'status': status, 'version': version};
}

class ShopClient {
  const ShopClient(this.models);

  final ShopModels models;
}

class ShopModels {
  const ShopModels(this.order);

  final OrderModel order;
}

class OrderModel {
  const OrderModel();

  Future<List<Order>> list() async => const [];
}

final shopClientProvider = Provider<ShopClient>((ref) {
  ref.watch(dio); // the generated client is built over this Dio
  return const ShopClient(ShopModels(OrderModel()));
});
```

```dart
// lib/app/orders/data.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:my_app/shop_client.dart';

/// Loaded again when a minute old and the app resumes or the network comes back.
const freshness = Freshness(staleTime: Duration(minutes: 1), refetchOnResume: true, refetchOnReconnect: true);

final _codec = ServedCodec<List<Order>>(
  toJson: (orders) => [for (final o in orders) o.toMap()],
  fromJson: (json) => [for (final m in json! as List<Object?>) Order.fromMap(m! as Map<String, Object?>)],
);

/// The server's orders; offline, the last ones this account loaded here (Served says which, and when).
FutureOr<Served<List<Order>>> data(Ref ref) => ref.serve(
  key: 'orders',
  codec: _codec,
  empty: () => const [],
  fetch: () {
    final client = ref.watch(shopClientProvider); // BEFORE cancellable: watch and read other providers first
    return ref.cancellable(() => client.models.order.list()); // the body is only the client call
  },
);
```

```dart
// lib/app/orders/page.dart
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';
import 'package:my_app/shop_client.dart';

class OrdersPage extends StatelessWidget {
  const OrdersPage(this.orders, {super.key});

  final Served<List<Order>> orders; // the type data() returns (or a typedef of it in your package, since 0.21.0, or in a `path:` dependency, since 0.22.0)

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (orders.source == ServedFrom.local) const Text('Offline copy'),
      for (final o in orders.value) Text('Order ${o.id}: ${o.status}'),
    ],
  );
}
```

- **`ref.cancellable` stops the request with the provider.** The generated options carry no cancel token, so the token
  travels in a **zone value** (`TransportZone`) that the `TransportAdapter` on the Dio picks up and merges into the request's
  abort trigger, so a Dio whose adapter is not a `TransportAdapter` never cancels a call made inside `ref.cancellable`.
  The cancelled call fails with `TransportAborted`, which `TransportFailures.read` reads as `CrateStackCancelled`. Call
  it **before the first `await`**. The body
  must be **only the client call**: a provider built _inside_ it runs in the same zone, so its own requests would take
  this provider's token and be cancelled with it (the symptom: another page's request is cancelled).
- **`freshness` decides _when_ a read runs again, `serve` _where_ the answer comes from.** Do not combine `serve` with
  `dataCache`.
- **The default `invalidates` of an action reloads `data` after any outcome**, `Queued` included. That is harmless: the
  read stays as the server says, and the "cancelling" overlay comes from `pendingIntents`.
- To read a generated provider with **no offline fallback**, select it as fespalier says
  (`ProviderListenable<AsyncValue<Order>> data(Ref ref, {required int id}) => orderProvider(id)`).

## 5. Actions are intents

```dart
// lib/app/orders/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:my_app/shop_client.dart';

typedef CancelInput = ({int orderId, int expectedVersion});

/// Cancelling is the server's decision: queued offline, sent with an idempotency key, decided once.
/// It never claims the order is cancelled before the server says so.
Future<IntentOutcome<Order>> cancel(Ref ref, {required CancelInput input}) => ref
    .read(intentQueue)
    .submit(
      // Your generated args: CancelOrderArgs(id: ..., expectedVersion: ...).toWire()
      RpcCall('cancelOrder', {'id': input.orderId, 'expectedVersion': input.expectedVersion}),
      subject: 'order:${input.orderId}',
      touches: const {'orders'},
      decode: (output) => Order.fromMap(output! as Map<String, Object?>),
    )
    .withCrateStackFieldErrors(ref);
```

`submit` returns `Accepted` or `Queued`; a refusal on the spot is thrown and nothing is kept; the call must be
JSON-native; a subject is ordered (`fespalier-offline`, [`fespalier-offline`](../fespalier-offline/SKILL.md) (its `intents.md` page)).
`withCrateStackFieldErrors(ref, fieldName: ...)` turns a `422` `VALIDATION_ERROR` (REST) or `invalid_argument` (RPC, since 0.21.0) into `FieldErrors`; the shape of
`details` is an **assumption** (CrateStack documents the message, not a structure).

## 6. Retries: one layer

Riverpod's data retry is the **one** retry layer for reads. A Dio retrier on top multiplies it (the two retry layers
multiply, `fespalier-data`, [`http.md`](../fespalier-data/SKILL.md) (its `http.md` page)), and generated RPC reads are POSTs that
`WriteGuard` refuses to repeat anyway. An intent has its own, slower retry: the next sync. Nothing here sleeps or backs
off with a timer.

## 7. Golden rules

- **The server must namespace idempotency keys by a verified principal.** The key is stored per namespace: the verified
  principal, else a hash of the `Authorization` header, else the peer address. With the `Authorization` fallback **a
  token refresh between two attempts changes the namespace**, so the replay of a call whose answer was lost is a new
  request and runs the call a second time. `fespalier_auth` refreshes lazily and a `401` keeps the same key, so this
  does happen. Configure the server's idempotency layer for the verified principal (the docs call it the first choice
  since CrateStack 0.14.0), and **do not queue a call whose double run matters against a server that cannot**. Details
  in [`references/server-contract.md`](references/server-contract.md).
- **`crateStackScope` must be the signed-in account**, and the sign-out wipe runs first (`fespalier-offline`).
- **Only intents and the row sync use `crateStackTransport`**; online reads keep using the generated client directly.
- **`HiveLocalStore.open` needs a directory off the web**, a folder the system does not empty (the application support
  directory, not a cache directory).

## Subscriptions (`@@subscribe`)

Since 0.25.0 `crateStackEvents(transport, base, opId)` reads `GET <base>/rpc/subscribe/<opId>` through the app's
`HttpTransport` as a `LiveConnection<CrateStackModelEvent>` (`fespalier_stream`'s `ServerEvents` and `EventCodec`), and the
usual use is `syncPushSignal.overrideWith((ref) => ref.watch(serverChanges.any))` over a `ChangeFeed.live` of it, so
`autoSync` syncs when a row changes on the server. The recipe and its test are in
[`fespalier-offline`](../fespalier-offline/SKILL.md) (its `push-sync.md` page). What CrateStack 0.15.4 does, measured, and what
it means:

- **No `id:` and `Last-Event-ID` ignored: every reopen is a gap.** A `ChangeFeed.live` moves every watched key and `any`
  then, so the app syncs once more. `CrateStackModelEvent.eventId` (a UUID) tells a duplicate after a reopen; `sequence`
  restarts on every connection.
- **A lagging subscriber is dropped** (past 64 buffered events): `event: error` with `unavailable` / `subscription lagged`,
  then the response ends. `crateStackEvents` drops the event; the connection opens again at once, a gap.
- **No heartbeat, so a silently dead connection is not found.** Leave `LiveRules.idle` unset (it would close a healthy quiet
  subscription). A `reconnectOn` signal and the `streamTicker` act on a connection that is _waiting_ (the ticker also on an
  idle or paused one), not on one that looks open. What replaces a dead one is a rebuild of the feed: have `connect` watch
  `appShowSignal`, and each show opens a new connection (no resume point: a gap, so one sync).
- **`connect` must watch the account** (`ref.watch(crateStackScope)`, or `authSession.select` as in `docs/streaming.md`
  "Sign-in and sign-out"). A feed that starts signed out is refused with a `401` (`ServerEventsRefused`) and nothing
  reopens it but a rebuild; after a sign-out the old connection would stay under the old session.
- **Per model, not per account, and your own push echoes back.** Every device of every user syncs when anyone writes, and the
  writer's device syncs twice per local edit (the push, then the echo). Bound `syncPushSignal` with a topic of the feed and a
  `ChangeBudget` (the recipe is in `fespalier-offline`'s `push-sync.md`).
- **No read policy at all on a subscription**: neither `@@allow("read")` nor the row policy is checked, and an anonymous
  caller gets every event unless the `AuthProvider` refuses it. Treat an event as a hint, read rows through the
  policy-checked API, never render `data` (not kept unless `keepData: true`), and make the server's `AuthProvider` (or a layer in front) refuse anonymous
  subscribers.
- **`Accept: text/event-stream` is required** (a 406 otherwise); `crateStackEvents` always sends it and replaces one given
  in `headers`. A device signature over the `GET` (an empty body) is expected to work and is UNCHECKED.
- `fespalier_cratestack` depends on `fespalier_stream` at the same `ref` since 0.25.0: an app that overrides it with a
  `path:` overrides `fespalier_stream` too.

## A transport that signs each attempt

When the server verifies a signature on every request, the signing goes **inside `CrateStackTransport.send`**, once per
attempt, and nowhere earlier. An intent stores the call as JSON and sends it from the store on every attempt, so each
attempt must be a new message (a fresh issue time and nonce, or the server's replay check refuses the second one) over the
same payload under the same `Idempotency-Key` (which a signature can bind). `examples/cose` is the worked case: a
COSE_Sign1 transport with a device key from `fespalier_keypair` (a signer for a protocol of your own, never DPoP, and not the
device sessions of `fespalier_sign_keypair`), sending through the app's one `HttpTransport` (`TransportRequest` in,
`TransportResponse` out, built once in `startup()`), a Rust CrateStack server that checks it, and an end-to-end test that
starts the server's binary. `examples/frb-cose` (since 0.21.1) is the same contract with the sealing
in CrateStack's own Rust, behind a flutter_rust_bridge core: the device key is still in Dart, which the core calls back to sign.

- **An unsigned `401` is `CrateStackUnauthenticated`**: the intent stays pending under the same key. Do not turn it into a
  retry inside the transport.
- **Only a sealed answer is the server's word.** An unsigned answer is believed for the refusals the envelope layer makes
  before the handler runs, by status alone and with its body ignored: `401` is `Unauthenticated`, `400`, `413`, `415` and
  `426` are `Refused` (code `HTTP_<status>`). **Every other unsigned answer is `CrateStackOffline`, same key**: a `5xx` would
  otherwise move the intent to the next key (the layer answers an unsigned `500` after the handler ran when it cannot seal),
  and a `409` or a `4xx` with a code chosen by whoever is on the path would drop it.
- **A sealed answer that does not open is `CrateStackOffline`, never `CrateStackUnavailable`.** The write may have landed;
  `Unavailable` moves the intent to the next key and risks a second write.
- **A read is still `ref.serve`**: only `CrateStackOffline` serves the copy, and a `401` is the answer.
- The key is registered by a plain call before the first signed one (a request signed by an unknown key is a `401`). The
  transport's `beforeSigned` hook runs before **every** signed call (the example's registrar makes the registration happen
  once, and `onUnauthenticated` forgets it after an unsigned `401`); whatever the hook throws is `CrateStackOffline`, same
  key, because the call was never sent.
- A server must answer the refusals it makes from the headers (a content type, a contract selector) as answers: read the
  body first, or the connection is closed with it unread and the client sometimes sees the reset before the answer (a
  `426` as `Offline`). `examples/cose/server` does, and its README says how it was measured.
- The server's `IdempotencyLayer` goes **inside** the envelope layer: it then hashes the plain CBOR (the same on every
  attempt, whatever the signature) and takes the verified device as its principal, and the replay is sealed anew.

This is not the "signed intents" below: a proof stored with a queued call, tied to the moment it was made.

## Messages and symptoms

The package's debug messages and what each one means are catalogued in
[`fespalier-troubleshooting`](../fespalier-troubleshooting/SKILL.md) (its `diagnostics-cratestack.md` page); the main ones:
`UnimplementedError: fespalier_cratestack: override crateStackTransport ...` (an intent or sync ran with no transport:
override it in `startup()`), `StateError: fespalier_cratestack: crateStackScope is null ...` (a `submit` or `OwnedRows`
call while signed out), `CrateStackNoLocalData` in `error.dart` (a single-row read with no answer and nothing stored), a
queued intent that never sends (no trigger runs: watch `autoSync`), and a call that ran twice after a token refresh (the
namespace rule above).

## Not built

Signed intents, paging helpers beyond `RowSync`'s cursor loop, resuming a subscription or applying its events to rows (an
event only starts a sync), sync telemetry spans (a data read through `serve` and an
action that calls `submit` already run inside fespalier's data and action spans; a sync span is planned as a custom op
(`TelemetryOp.custom`, since 0.11.0, named `fespalier.cratestack.sync`; no new `TelemetryOp` value, so no exhaustive sink breaks), and nothing from an intent, a row, a subject or a server message would ever be sent), and a background
isolate.

## References

| Need                                                                                                    | Page                                                                  |
| ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| The whole `startup()`, the Dio, the root layout, sign-out, `path_provider`, the web                     | [`references/wiring.md`](references/wiring.md)                        |
| What the server's idempotency layer guarantees, the answer table, what `RowSync`'s procedures must do   | [`references/server-contract.md`](references/server-contract.md)      |
| Where CrateStack's embedded SQLite mode fits and where it does not                                      | [`references/embedded-mode.md`](references/embedded-mode.md)          |
| Reads, intents, owned rows, sync, testing                                                               | [`fespalier-offline`](../fespalier-offline/SKILL.md)                  |
| A subscription that makes `autoSync` sync by push, and its test (since 0.25.0)                          | [`fespalier-offline`](../fespalier-offline/SKILL.md) (`push-sync.md`) |
| A transport that signs every request and a server that checks it, end to end                            | [`examples/cose`](../../examples/cose/README.md)                      |
| A generated client (`--preset fespalier`, no Dio), a Rust server and device-signed sessions, end to end | [`examples/cratestack`](../../examples/cratestack/README.md)          |
| What a call costs in bytes as JSON, CBOR and `COSE_Sign1` CBOR, counted in process (no socket)          | [`examples/wire-sizes`](../../examples/wire-sizes/README.md)          |
| A Rust core that is CrateStack's client, behind flutter_rust_bridge (since 0.21.1)                      | [`examples/frb-cose`](../../examples/frb-cose/README.md)              |

## Where the code is

`packages/fespalier_cratestack/lib/`: `fespalier_cratestack.dart` (with `src/portal_transport.dart`,
`src/transport_cancel.dart`, `src/transport_failures.dart` and, since 0.25.0, `src/subscription.dart`), `hive.dart`, `testing.dart`, and `src/transport.dart` (`CrateStackTransport`, `RpcCall`, `RestCall`,
`crateStackTransport`). The guide is
[`docs/cratestack.md`](https://github.com/fespalier/fespalier/blob/main/docs/cratestack.md).

`examples/offline` (in the fespalier repository) is the wiring without a CrateStack server to start: `lib/wiring.dart`
overrides the transport, the error reader (`lib/errors.dart`), `crateStackScope` and the `RowSync`, over a demo server
in process that plays the part of the generated client.
