# Testing offline

Since 0.10.0 (`package:fespalier_cratestack/testing.dart`). The fakes play the server, so a test can lose the network,
lose an answer, refuse a call, and watch a queued intent still send a year later, all with **no timer**: every answer
is a `Future.value`.

```dart
// test/offline_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

Future<IntentOutcome<Object?>> cancel(ProviderContainer container) => container
    .read(intentQueue)
    .submit(
      const RpcCall('cancelOrder', {'id': 42}),
      subject: 'order:42',
      touches: const {'orders'},
      decode: (output) => output,
    );

void main() {
  late FakeCrateStackTransport transport;
  late ProviderContainer container;

  setUp(() {
    transport = FakeCrateStackTransport()..on('cancelOrder', (input) => {'id': 42, 'status': 'cancelled'});
    // A synchronous in-memory store, a signed-in scope ('test-user') and no lifecycle trigger.
    container = ProviderContainer(overrides: crateStackTestOverrides(transport: transport));
    addTearDown(container.dispose);
  });

  test('offline, a decision is queued; online, a drain sends it once', () async {
    transport.offline = true;
    expect(await cancel(container), isA<Queued<Object?>>());
    expect(transport.runs('cancelOrder'), 0);

    transport.offline = false;
    final report = await container.read(intentQueue).drain();
    expect(report.accepted, 1);
    expect(transport.runs('cancelOrder'), 1);
    expect(await container.read(intentQueue).list(), isEmpty);
  });

  test('a lost answer is replayed under the same key and runs once', () async {
    transport.loseAnswer('cancelOrder'); // the call runs on the server, the answer never arrives
    expect(await cancel(container), isA<Queued<Object?>>());

    await container.read(intentQueue).drain();
    expect(transport.runs('cancelOrder'), 1); // the replay got the stored answer
    expect(transport.calls.map((c) => c.idempotencyKey).toSet(), hasLength(1));
  });

  test('a refusal on the spot is thrown and nothing is kept', () async {
    transport.refuse('cancelOrder', 403, 'FORBIDDEN', 'not yours');
    await expectLater(cancel(container), throwsA(isA<CrateStackRefused>()));
    expect(await container.read(intentQueue).list(), isEmpty);
  });

  test('an edit made offline is pushed by a sync', () async {
    final server = FakeRowServer();
    final synced = ProviderContainer(
      overrides: crateStackTestOverrides(rowServer: server, collections: ['notes']),
    );
    addTearDown(synced.dispose);

    await synced.read(ownedRows).edit('notes', 'n1', {'title': 'Milk'});
    final report = await synced.read(syncRunner).sync(SyncReason.manual);

    expect(report.pushed, 1);
    expect(server.row('notes', 'n1')!.fields['title'], 'Milk');
  });

  test('the app tick starts a sync', () async {
    final server = FakeRowServer();
    final ticking = ProviderContainer(
      overrides: [
        ...crateStackTestOverrides(
          rowServer: server,
          collections: ['notes'],
          triggers: const SyncTriggers(onStart: false, onResume: false, onReconnect: false),
        ),
        syncTicker.overrideWith(ManualSyncTicker.new),
      ],
    );
    addTearDown(ticking.dispose);
    final watch = ticking.listen(autoSync, (_, _) {}); // autoSync lives while watched
    addTearDown(watch.close);

    await ticking.read(ownedRows).edit('notes', 'n1', {'title': 'Milk'});
    (ticking.read(syncTicker.notifier) as ManualSyncTicker).tick();
    await pumpEventQueue();

    expect(server.pushes, hasLength(1));
  });
}
```

- **`crateStackTestOverrides({transport, store, scope = 'test-user', triggers, rowServer, collections, lifecycle = false})`**
  wires a synchronous `InMemoryLocalStore`, a signed-in scope and, unless `lifecycle: true`, a resume signal that never
  fires (a bare container has no `WidgetsBinding`). Pass `scope: null` to test the signed-out `StateError`; pass one
  `store` to two containers to test a restart.
- **`FakeCrateStackTransport`** plays the server **including its idempotency layer**: a replay under the same key
  returns the stored answer and does not run twice, and the same key with another body answers `422`
  `idempotency_key_conflict`. `on(name, handler)` scripts a call (a name is the RPC op id, or `METHOD path` for a
  REST call), `offline = true` fails everything as `CrateStackOffline`, `loseAnswer('op', times: 1)` runs the call and
  drops the answer, `refuse('op', status, code, message, {details, retryAfter, times})` and `fail('op', error)` script
  failures, `heal('op')` stops them, `runs('op')` counts executions and `calls` records every send with its key.
  A call nobody scripted throws `StateError: FakeCrateStackTransport: nothing scripted for "<op>" (use on())`.
- **`FakeRowServer({pageSize = 100, rejectCode = 'FORBIDDEN'})`** is a `RowSync` that merges per field, pages its
  pulls, goes `offline`, and refuses the ids in `rejectIds`; `pushes`, `pulls`, `row(collection, id)` and `put(row)`
  are for assertions and for seeding.
- **`ManualSyncTicker.tick()`** fires the app tick without a timer. Use it as `syncTicker.overrideWith(ManualSyncTicker.new)`.
  The reconnect trigger is `FakeConnectivity` from `fespalier_connectivity` (`reconnectSignal.overrideWith(ConnectivitySignal.new)`).
  The resume trigger is `tester.binding.handleAppLifecycleStateChanged`, with `lifecycle: true`.
- **The clock** is `package:clock`: `fetchedAt`, the HLC and `minInterval` follow `withClock(...)` and a `testWidgets`
  fake clock, so pump a day or a year and watch an intent still send.
- **No timers.** The package starts none, so a `testWidgets` that ends with "A Timer is still pending" has your own
  (an un-overridden `ForegroundTicker`, a `Timer.periodic` in a fake). Override `syncTicker` with `ManualSyncTicker`.
- To test a page, use `pumpRouter` with `crateStackTestOverrides(...)` plus your fake client, as in
  [`fespalier-testing`](../../fespalier-testing/SKILL.md).

## Where the code is

`packages/fespalier_cratestack/lib/testing.dart`; the package's own `test/intents_test.dart` pins the answer table,
`test/no_timers_test.dart` greps `lib/` for timers, delays, listeners and `DateTime.now()`.
