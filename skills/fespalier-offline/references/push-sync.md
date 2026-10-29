# A push from the server

Since 0.25.0. `autoSync` syncs when the server says something changed: it follows `syncPushSignal`, a count the app
overrides, usually with the `any` of a change feed over the server's own event stream. With CrateStack that stream is a
subscription (`@@subscribe`), which `crateStackEvents` reads through the app's `HttpTransport` (`fespalier_stream`'s
`ServerEvents` under it, so a session or a signature applies).

```dart
// lib/server_changes.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

/// The transport every call goes through (a session, a signature), built in startup().
final apiTransport = Provider<HttpTransport>(
  (ref) => throw UnimplementedError('override apiTransport in startup()'),
);

/// The CrateStack server.
final apiBase = Uri.parse('https://api.example.com/');

/// The server's changes to notes. No `idle`: CrateStack sends no heartbeat, so a quiet subscription would be
/// closed while healthy. A drop waits for one of these signals, or for the app's streamTicker.
final serverChanges = ChangeFeed<CrateStackModelEvent>.live(
  (ref, _) {
    // Who is signed in. The feed opens at start, usually signed out, and the server's 401 ends it
    // (ServerEventsRefused); only a rebuild opens it again, and signing in is one. Sign-out and another
    // account replace the connection too, so one account never reads under the other's session.
    ref.watch(crateStackScope);
    return crateStackEvents(ref.watch(apiTransport), apiBase, 'model.Note.subscribe');
  },
  rules: LiveRules(reconnectOn: [reconnectSignal]),
  name: 'serverChanges',
);

/// The override startup() returns: a sync each time the server says a note changed, and after each gap.
final serverPush = syncPushSignal.overrideWith((ref) => ref.watch(serverChanges.any));
```

What `SyncReason.push` does that the other triggers do not:

- **It skips `minInterval`.** The server just said there is something to pull.
- **It is never joined to a running sync.** That sync may already have pulled past the change, so a push during a run
  marks the engine dirty and **one more sync runs after it**; every push until that one starts joins it. A burst gives
  two syncs, never more, and nothing waits on a timer. Joining it (what `resume` or `tick` do) would lose the change.
- **A gap is a push.** CrateStack 0.15.4 sends no `id:` and ignores `Last-Event-ID`, so every reopen (after a drop, after
  the server dropped a subscriber that lagged, after the tick closed a paused connection) is a gap, which moves `any` by
  one: the app syncs, since it may have missed an event.
- **A signal that throws is ignored**, and the other triggers keep working.
- **A `SyncRunner` of your own** (a Rust core) gets `SyncReason.push` too and decides itself what a push during a run
  means. A `switch` over `SyncReason` that lists every value needs a `push` case since 0.25.0.

The traps:

- **Never render from an event.** CrateStack 0.15.4 checks no read policy on a subscription, neither `@@allow("read")`
  nor the row policy: the row in an event is the row as written, sent to every subscriber (`CrateStackModelEvent.data` is
  null unless you pass `keepData: true` to `crateStackEvents`: the feed keeps its last 64 events). The sync pulls through
  your procedures, and the page shows the rows. `onSkipped` hears a bad message with an error that quotes it: log its type. `toString` prints the model and the operation only.
- **The `AuthProvider` is the only gate.** An anonymous subscriber gets every event unless the server's `AuthProvider`
  (or a layer in front of the router) refuses it. A refusal (`401`, or the `406` of a missing `Accept`) ends the
  connection with `ServerEventsRefused`; `crateStackEvents` always sends `Accept: text/event-stream`.
- **A feed that fails is a push trigger that never fires**, with no error anywhere `autoSync` shows: its `latest` holds
  the error and `any` stays where it was. A refusal is one cause, and it ends the feed until it is rebuilt, which is why
  `connect` watches `crateStackScope`. In a bare `ProviderContainer` test, a `reconnectOn` signal that needs a
  `WidgetsBinding` (`appShowSignal`, `appResumeSignal`) is another: override it with `RefetchSignal.new`, or use
  `testWidgets`. Watch `serverChanges.latest` for a banner if it matters.
- **A connection that died silently is not found.** There is no heartbeat, so no `idle`; a `reconnectOn` signal and the
  `streamTicker` act on a connection that is _waiting_ (the ticker also on an idle or paused one), never on one that
  looks open. What replaces it is a rebuild of the feed: add `ref.watch(appShowSignal)` to `connect` and each show of
  the app opens a new connection, which has no resume point, so it is a gap and one sync. (Override `appShowSignal`
  with `RefetchSignal.new` in a bare container.) The other triggers keep syncing meanwhile.
- **It reaches every device of every user, and your own writes echo.** A subscription is per model, with no per-account
  filter: when anyone writes a `Note`, every connected device syncs, and the writer's device syncs twice for one local
  edit (the push, then the echo's). `any` has no budget; bound it with a topic and a `ChangeBudget`, which moves at most
  once between two ticks of a signal your own timer fires, still at once for the first event after a quiet period, and
  loses nothing (the held events move it once at the next tick):

```dart
// lib/push_budget.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:my_app/server_changes.dart';

/// Ends a period of the budget. It never fires by itself: the timer is the app's, and it runs only while
/// something watches the topic and is not paused.
final syncPushTick = NotifierProvider.autoDispose<RefetchSignal, int>(PushTick.new);

class PushTick extends RefetchSignal {
  Timer? _timer;

  void _start() => _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => fire());

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  int build() {
    _start();
    ref.onCancel(_stop);
    ref.onResume(_start);
    ref.onDispose(_stop);
    return 0;
  }
}

/// Every event, or `event.model == 'Note'` for one model, at most once per tick.
final syncPushTopic = serverChanges.topic<Object?>(
  (event, _) => true,
  budget: ChangeBudget(syncPushTick),
);

/// The override startup() returns instead of `serverPush`.
final boundedPush = syncPushSignal.overrideWith((ref) => ref.watch(syncPushTopic(null)));
```

- **Watch it where it lives as long as the app.** `ChangeFeed.live` keeps its connection while the container lives,
  and `autoSync` (watched in the root layout) watches the signal, so the subscription opens with the app. A page that
  wants to move on one model's events watches a topic of the same feed (`serverChanges.topic<String>((e, m) => e.model ==
m)`), not a second connection.

```dart
// test/push_sync_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/server_changes.dart';

void main() {
  test('an event syncs by push; a lag is a gap, which syncs again', () async {
    final events = FakeEventServer(); // plays the subscription
    final rows = FakeRowServer(); // plays the row procedures
    final container = ProviderContainer(
      overrides: [
        ...crateStackTestOverrides(rowServer: rows, collections: ['notes']),
        ...streamTestOverrides(),
        apiTransport.overrideWithValue(events),
        serverPush,
      ],
    );
    addTearDown(container.dispose);
    final watch = container.listen(autoSync, (_, _) {});
    addTearDown(watch.close);
    await pumpEventQueue();
    expect(rows.pulls, 1); // the start sync
    expect(events.current.request.uri.path, '/rpc/subscribe/model.Note.subscribe');

    events.current.modelEvent('Note', 'Updated', data: {'id': 1});
    await pumpEventQueue();
    expect(rows.pulls, 2); // inside minInterval, and not skipped

    events.current.lagged(sequence: 2); // `event: error`, then the server ends the response
    await pumpEventQueue();
    expect(events.connections, hasLength(2)); // opened again, with no ID to resume from
    expect(rows.pulls, 3);
  });
}
```

`modelEvent(model, operation, {data, sequence, eventId, occurredAt})` and `lagged({sequence})` are extensions on
`fespalier_stream`'s `FakeEventConnection` in `package:fespalier_cratestack/testing.dart`; they write the bytes
CrateStack 0.15.4 writes. Nothing here starts a timer; under `fake_async`, Riverpod's own zero-length scheduler timer
needs `async.elapse(Duration.zero)`.

## Where the code is

`packages/fespalier_cratestack/lib/src/subscription.dart` (`crateStackEvents`, `CrateStackModelEvent`,
`crateStackEventCodec`, `crateStackSubscribeUrl`), `sync_engine.dart` (`SyncReason.push`, the dirty bit) and
`auto_sync.dart` (`syncPushSignal`, `SyncTriggers.onPush`); `test/push_sync_test.dart` and `test/subscription_test.dart`
(the bytes a 0.15.4 server wrote). `examples/offline` reads its demo server's subscription: "Rename on the other phone"
reaches the open note by push. The guides are
[`docs/offline-first.md`](https://github.com/fespalier/fespalier/blob/main/docs/offline-first.md#a-push-from-the-server)
and [`docs/cratestack.md`](https://github.com/fespalier/fespalier/blob/main/docs/cratestack.md#subscriptions-subscribe).
