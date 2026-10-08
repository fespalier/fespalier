# Offline-first with fespalier

How an app that keeps working without a network is built on fespalier (since 0.10.0): what is read from the
device, what is written locally, and what must wait for the server. The code is `fespalier_cratestack`; the wiring
for a CrateStack client is in [CrateStack with fespalier](cratestack.md). The ideas here do not depend on it.

## Two kinds of writes

Everything a user changes is one of two kinds, and the two are handled differently.

|                 | Rows a user **owns**                   | **Decisions** only the server makes                                    |
| --------------- | -------------------------------------- | ---------------------------------------------------------------------- |
| Examples        | a note, a draft, a to-do, a setting    | cancel an order, accept an invitation, transfer a balance              |
| Written         | on the device at once, offline or not  | as an **intent**: saved, sent, and decided by the server               |
| Conflicts       | merged field by field, nobody is asked | the server answers, the person resolves a conflict                     |
| The page shows  | the new value immediately              | "will send when back online", never a success the server has not given |
| In this package | `OwnedRows`, `RowSync`                 | `IntentQueue`                                                          |

Some calls stay **online-only, on purpose**: a one-time code, a stock reservation, anything that has to be
answered now. Do not queue them. A call that should fail when there is no network is a feature.

## Reads

```dart
FutureOr<Served<List<Order>>> data(Ref ref) => ref.serve(
  key: 'orders',
  codec: _codec,
  empty: () => const [],
  fetch: () => ref.read(shopClient).models.order.list(),
);
```

A read has a policy:

| Policy                   | Looks first at                                      | Use it for                                                                                |
| ------------------------ | --------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `networkFirst` (default) | the server, then the device on a connection failure | anything others can change                                                                |
| `cacheFirst`             | the device, then the server if there is nothing     | data that does not change once saved                                                      |
| `localOnly`              | the device only, the copy an earlier read saved     | data that is only ever read here (rows this device owns are read from `ownedRows`, below) |
| `serverOnly`             | the server only; offline is an error, never a guess | what must be current                                                                      |

The rules that keep it honest:

- **Only a connection failure falls back.** A refusal is the answer: a `403` is not "the network is down", and
  showing last week's copy of something you may no longer see would be a leak. The refusal is rethrown to
  `error.dart`. That holds on a route with a `freshness` too (since 0.13.1): `CrateStackRefused` is a `DataRefusal`, so the `DataView`'s `keepDataOnError` keeps the page for an offline reload but shows `error.dart` instead of the old copy for any refusal (a 404, 429 or 400 included: every `4xx` but 401 and 409). Before 0.13.1 the old `Served` copy stayed on screen: watch `reconnectSignal` in `data.dart` instead of declaring `freshness` there.
- **An empty list offline is an answer.** `Served` says `neverFetched`, and the page can say "not loaded on this phone
  yet" instead of "you have no orders".
- **A single row with nothing saved is an error.** `CrateStackNoLocalData`, shown with a retry. There is no empty row
  to invent.
- **Every answer says where it came from and as of when**, per account. One account's copy never reaches
  another: the scope is part of every key.
- **A gateway or a captive portal counts as offline.** An HTML page where a JSON answer was expected, or a
  `502`, `503`, `504`, `511` with no CrateStack envelope, means nobody that knows your API answered. A bare
  `500` does not: the server did answer. With Dio, add `CrateStackPortalInterceptor`: Dio does not throw on an HTML
  `200`, so without it the page reaches the client as a decoding error that no reader knows.

The `Freshness` rules of `data.dart` (`staleTime`, `refetchOnResume`, `refetchOnReconnect`) still say _when_ a
read runs again; `serve` says where its answer comes from.

## Intents

```dart
final out = await ref.read(intentQueue).submit(
  const RpcCall('cancelOrder', {'id': 42, 'expectedVersion': 3}),
  subject: 'order:42',
  touches: const {'orders'},
  decode: (o) => Order.fromJson(o! as Map<String, Object?>),
);

switch (out) {
  Accepted(:final value) => showCancelled(value),
  Queued() => showSaved('It will be sent when you are back online'),
}
```

What an intent is:

- **A stored call.** The call is encoded once and saved before it is sent, then sent from the saved text every time.
  Every attempt is byte-identical, which is what a server's idempotency check compares.
- **A key, `<id>#<attempt>`.** The `id` is 128 random bits. The same key is used until the server answers with a
  stored failure (`5xx`); then the next attempt gets the next number, because a stored failure may be replayed
  under the old one. A replay is only safe if the server keys its idempotency store by a verified principal:
  keyed by a hash of the `Authorization` header, a token refresh between attempts makes the replay a new request
  (see [CrateStack with fespalier](cratestack.md#5-actions)).
- **Never expiring.** An intent stays on the device until the server decides or the person discards it. The
  server's idempotency window is the only bound on "never".
- **Wiped at sign-out.** Sending one account's intent under another's session is worse than losing it.
  `crateStackAccount.clear()` removes the intents, rows and cached reads of the account.
- **Ordered per subject.** An intent waits behind an undecided earlier one with the same `subject`
  (`order:42`), so "pay" never overtakes "edit address" for the same order. That holds for a `submit` too: behind an
  undecided intent it is saved and `Queued`, not sent. Intents for other subjects do not wait.
- **JSON-native.** The call is stored as JSON: maps, lists, strings, numbers, booleans, `null`. Bytes would silently
  become a list, so send them as text.

The answer table is in [CrateStack with fespalier](cratestack.md#5-actions). In short: no answer, in flight and
`401` keep the key; a stored failure takes the next; a refusal is kept `failed` with its wire code (never the
server's message, which may quote values); a conflict is kept for the person.

**Never fake success.** `submit` returns `Accepted` only when the server said yes. A queued intent is `Queued`, and
the page says so. An optimistic overlay (a row that reads "cancelling...") comes from `pendingIntents`, not from
pretending the order is already cancelled.

## Owned rows

```dart
final rows = ref.read(ownedRows);

// A note, edited offline: stamped, saved, and marked dirty.
await rows.edit('notes', 'n1', {'title': 'Groceries', 'body': 'Milk'});
await rows.remove('notes', 'n1'); // a tombstone, a field like any other

// A page reads them locally: synchronous with a synchronous store, so on the first frame.
FutureOr<List<OwnedRow>> data(Ref ref) {
  ref.watch(crateStackRevision('notes')); // an edit or a sync rebuilds the read
  // The rows are the signed-in account's: a read while signed out is empty, not an error.
  if (ref.watch(crateStackScope) == null) return const [];
  return ref.watch(ownedRows).list('notes');
}
```

How two devices that edit the same row end up the same:

- **A field is the unit.** Each field carries the stamp of the write that set it. Two devices that edit different
  fields of the same row both keep their edit. For the same field, the greater stamp wins, on both devices,
  whatever order the rows arrive in (the merge is commutative, associative and idempotent).
- **The stamp is a hybrid logical clock.** Wall milliseconds, a counter and a random node id for the device,
  totally ordered. When a device receives a row, its clock moves past every stamp in it. So "latest" means
  causally later, not "whose wall clock was ahead": a phone whose clock is wrong cannot make a later edit lose to an
  earlier one it has already seen.
- **A delete is a field.** The tombstone (`deletedAt`) is stamped like any other field, so a delete and a concurrent edit
  of another field both survive.
- **A read never overwrites an unpushed edit.** A row arriving from the server replaces the clean fields; a
  dirty field keeps the local edit unless the server's stamp is newer.
- **A refused row rolls back, out loud.** If the server rejects a row, the device returns to the server's version (or
  drops a row the server never took), and the sync report lists it with the reason code only.

CrateStack has no sync protocol of its own, so `RowSync` is two procedures you add to your schema (say `syncPush`
and `syncPull`). The server side merges with the same per-field rule and writes through the model layer, so policies
still apply to what a device pushes.

## Sync

```dart
final report = await ref.read(syncRunner).sync(SyncReason.manual);
if (report.rolledBack.isNotEmpty) showUndone(report.rolledBack);
```

A sync does three things, in this order: **push** the dirty rows, **pull** each collection, then **drain** the
intents. The order matters: an intent may name a row made offline, and the server must have the row first. The drain
runs even when the push failed, and stops at the first sign of no network.

- **Single flight.** A sync that starts while another runs joins it and gets the same result.
- **A minimum interval.** A sync started by a signal (resume, reconnect, the app's tick) within `minInterval`
  (10 seconds by default) of the last one that reached the server does nothing, unless the last one found no
  network or work has been queued since (an intent, an edited row). A manual sync, and the first one at start,
  always run.
- **It never throws.** The report says what failed (`failure`), what was pushed, what was pulled, and what the drain did.

## Triggers

`autoSync`, watched once in the root `layout.dart`, runs a sync on four occasions, and each one exists for a reason:

| Trigger        | Why it is needed                                                                  |
| -------------- | --------------------------------------------------------------------------------- |
| start          | work queued in the last session should not wait for an event                      |
| resume         | the app came back; the device may have been offline for hours                     |
| reconnect      | the network came back while the app stayed open                                   |
| the app's tick | a device that never backgrounds and never loses signal would otherwise never push |

The first three come from fespalier: `appResumeSignal`, `reconnectSignal` (override it with
`ConnectivitySignal.new` from `fespalier_connectivity`) and the start of `autoSync`. The tick is a signal the
package never fires itself, because it starts no timer; the app owns the timer, its period and its test:

```dart
class ForegroundTicker extends RefetchSignal {
  @override
  int build() {
    final t = Timer.periodic(const Duration(minutes: 5), (_) => fire());
    ref.onDispose(t.cancel);
    return 0;
  }
}
// startup(): syncTicker.overrideWith(ForegroundTicker.new)
```

It is `autoDispose` and watched only by `autoSync`, so the timer exists only while the app shows the root layout.

Two patterns around the triggers:

- **Save locally, then sync best-effort.** An action edits the row, then calls `engine.sync(SyncReason.manual)` and
  ignores a failure: the triggers will try again. The person never waits for the network to save. That report does not reach `autoSync`'s state, so to tell the person about a `rolledBack` row keep it yourself (the [offline example](examples.md#offline) does, in a `lastSync` notifier).
- **Push before a server decision that depends on a local row.** An action that asks the server to act on a row made
  offline calls `await ref.read(syncEngine).push()` first. Unlike `sync`, `push()` throws: if the rows are not on the
  server, say so rather than send a decision that names a row the server has never seen.

## Freshness in the UI

`Served` and `pendingIntents` are what a banner is made of.

```dart
final waiting = ref.watch(pendingIntents(null)).value ?? const [];
final status = ref.watch(autoSync); // isSyncing, and the last report

if (orders.source == ServedFrom.local)
  Text(orders.neverFetched ? 'Offline: not loaded on this phone yet' : 'Offline copy, as of ${orders.fetchedAt}'),
if (waiting.isNotEmpty) Text('${waiting.length} changes waiting to send'),
```

Show the time rather than the word "stale": a person can judge "as of 10:42". `stale` follows the `maxAge` you pass
to `serve`, for the screens where an old answer needs a warning.

## Testing offline

- **The fakes.** `FakeCrateStackTransport` plays the server, including the idempotency layer. `FakeRowServer` is a
  row server that merges and can refuse by id. `crateStackTestOverrides` wires them with a synchronous store and a
  signed-in scope.
- **The clock.** Everything reads `package:clock`: use `withClock` or a `testWidgets` fake clock, then pump a day or a
  year and watch an intent still send.
- **The triggers.** `ManualSyncTicker.tick()` for the tick; `FakeConnectivity` for the network; the lifecycle through
  `tester.binding.handleAppLifecycleStateChanged`.
- **No timers.** Nothing in the package starts one, so a `testWidgets` that ends with a timer pending points at
  your own code.

## Limits

- **No signed intents.** A queued call cannot carry a proof tied to the moment it was made (a re-confirmation, a
  device-bound proof). Keep those calls online-only.
- **No paging helpers yet** beyond the cursor loop of `RowSync.pull`.
- **One isolate.** Sync runs while the app is open. A background sync is the app's to build, and it needs a store that
  a second isolate can open safely.
- **The web.** Use `InMemoryLocalStore` (nothing outlives the tab) or `HiveLocalStore` on IndexedDB. Both are
  synchronous after opening, so `localOnly` reads stay on the first frame.
- **Where the embedded CrateStack fits** is in [CrateStack with fespalier](cratestack.md#8-where-cratestacks-embedded-mode-fits).
