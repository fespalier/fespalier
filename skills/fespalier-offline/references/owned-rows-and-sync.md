# Owned rows, the merge and the sync engine

Since 0.10.0. A device that edits rows while offline keeps them in `OwnedRows` and syncs them with a `RowSync` the app
writes over **two procedures in its schema**: CrateStack has no sync protocol of its own, so the push and the pull belong
to the app. The server side must apply the **same per-field rule** and write through the model layer, so policies still
apply to what a device pushes.

## The clock and the merge

- **A field is the unit.** Each field of an `OwnedRow` carries the stamp of the write that set it (`stamps`), and the
  fields edited here and not yet acknowledged are `dirty`. Two devices that edit different fields of one row both keep
  their edit; for the same field the greater stamp wins, on both, whatever order the rows arrive in (`LwwMerge.merge` is
  commutative, associative and idempotent).
- **The stamp is a hybrid logical clock** (`Hlc`): wall milliseconds from `package:clock`, a counter and the random
  node id of the device, ordered as `(millis, counter, node)` and packed as text that sorts as text. When a row arrives,
  the local clock moves past every stamp in it, so "latest" means causally later: a phone with a wrong clock cannot
  make a later edit lose to an earlier one it has already seen.
- **A delete is a field.** `remove` sets `deletedAt` (`tombstoneField`), stamped like any other, so a delete and a
  concurrent edit of another field both survive. `OwnedRow.deleted` reads it.
- **A read never overwrites an unpushed edit.** `LwwMerge.adopt` (what a pull and an accepted push use): per field the
  greater stamp wins, and a dirty field keeps the local edit while its stamp is greater; at an equal stamp the server has
  it and the field is clean.
- **A refused row rolls back, out loud.** If the server rejects a row, the device returns to the server's version (or
  drops a row the server never took) and the `SyncReport` lists it as `RolledBack(collection, id, code)`: the wire code
  only, never the server's message.
- The API: `edit(collection, id, changes)`, `remove(collection, id)`, `get`, `list(collection)`, `dirty(collections)`,
  `adopt(serverRows)`, `discard(collection, id)`, `cursor` and `setCursor`. A read while **signed out** throws
  `StateError: fespalier_cratestack: crateStackScope is null (nobody is signed in), so owned rows cannot be read or written.`
  (a `data.dart` returns `const []` instead). Synchronous with a synchronous store, so a list is on the first frame.
- **Revisions.** An edit bumps `crateStackRevision(collection)`; a sync bumps what it changed; an accepted intent bumps
  its `touches`. A `data.dart` watches the tag it reads.

## Writing a `RowSync`

```dart
// lib/note_sync.dart
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// Two procedures of the app's own schema: syncPush and syncPull.
class NoteSync implements RowSync {
  NoteSync(this._transport);

  final CrateStackTransport _transport;

  @override
  Future<PushResult> push(List<OwnedRow> dirty) async {
    final answer =
        (await _transport.send(RpcCall('syncPush', {'rows': [for (final row in dirty) row.toJson()]})))!
            as Map<String, Object?>;
    return PushResult(
      accepted: [for (final row in answer['accepted']! as List<Object?>) OwnedRow.fromJson(row)],
      rejected: [for (final row in answer['rejected']! as List<Object?>) _rejection(row)],
    );
  }

  @override
  Future<PullPage> pull(String collection, String? cursor) async {
    final answer =
        (await _transport.send(RpcCall('syncPull', {'collection': collection, 'cursor': cursor})))!
            as Map<String, Object?>;
    return PullPage(
      [for (final row in answer['rows']! as List<Object?>) OwnedRow.fromJson(row)],
      nextCursor: answer['next'] as String?, // saved after the page is applied
      hasMore: answer['more'] == true, // another page follows right away
    );
  }
}

RowRejection _rejection(Object? json) {
  final r = json! as Map<String, Object?>;
  return RowRejection(
    collection: r['collection']! as String,
    id: r['id']! as String,
    code: r['code']! as String, // the wire code only, never the server's message
    server: r['server'] == null ? null : OwnedRow.fromJson(r['server']), // roll back to it, or drop the row
  );
}
```

```dart
// lib/app/startup.dart
import 'package:fespalier/startup.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:my_app/note_sync.dart';

Future<List<Override>> startup() async => [
  rowSync.overrideWith((ref) => NoteSync(ref.watch(crateStackTransport))),
  syncCollections.overrideWithValue(const ['notes']), // pushed and pulled on every sync
];
```

- `push(dirty)` gets the dirty rows (with every field's stamp) and answers the rows **as the server now has them**
  (`accepted`: the merged truth) and the ones it refused. `pull(collection, cursor)` answers a page of rows changed
  since the cursor (`null`: all of them), with `nextCursor` and `hasMore`; the engine saves the cursor only after the page
  is applied. Both throw what the client throws, and `CrateStackErrors` classifies it. `rowSync` is `null` by default:
  an app with intents only has none.
- The two calls above send **without** an idempotency key. They are safe to repeat because the merge is idempotent: do
  not queue them as intents.

## `SyncEngine` and `autoSync`

`syncEngine` (per account) runs, in this order: **push** the dirty rows, **pull** each collection in `syncCollections`,
then **drain** the intent queue (an intent may name a row made offline, so the server needs the row first). The drain
runs even when the push failed and stops at the first sign of no network. `syncRunner` is what `autoSync` runs: override
it with your own `SyncRunner` (a Rust core behind `flutter_rust_bridge`, say) and keep `autoSync`, the triggers, `Served`
and `IntentOutcome`.

`SyncReport`: `reason`, `reachedServer`, `pushed`, `pulled`, `rolledBack`, `intents` (a `DrainReport`), `failure` (the
first, a `CrateStackFailure`) and `skipped`. **A sync never throws.** An error no reader knows becomes
`CrateStackUnavailable(status: 0, code: 'unknown')` with a debug line:
`fespalier_cratestack: a sync failed with an error no reader knows: <Type>`.

| Trigger            | Provider and reason                                                 | Needs                                                                             |
| ------------------ | ------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| start              | `SyncReason.start`: the first build of `autoSync`                   | `ref.watch(autoSync)` in the root `layout.dart`                                   |
| resume             | `appResumeSignal`, `SyncReason.resume`                              | a `WidgetsBinding` (tests turn it off)                                            |
| reconnect          | `reconnectSignal`, `SyncReason.reconnect`                           | `reconnectSignal.overrideWith(ConnectivitySignal.new)` (`fespalier_connectivity`) |
| the app's tick     | `syncTicker`, `SyncReason.tick`                                     | `syncTicker.overrideWith(...)` with a ticker **you** own (a `RefetchSignal`)      |
| a person or action | `SyncReason.manual`: `ref.read(syncRunner).sync(SyncReason.manual)` | nothing; it always runs                                                           |

`syncTriggers` (`SyncTriggers(onStart:, onResume:, onReconnect:, onTick:)`, all on by default) turns triggers off.
`autoSync` watches the signals and compares counts it kept (no listener of its own), starts the sync with a side
`then` (a sync bumps other providers, which Riverpod forbids during a build), and **sets `retry` to null** because
Riverpod's own retry waits on a timer. Its state is `SyncStatus(isSyncing, last)`.

`minInterval` (10 s by default, on `SyncEngine`) skips a **signal**-started sync that follows the last one that reached
the server too closely, unless the last found no network or there is new work (an undecided intent beyond what the last
drain left, a dirty row). `SyncReport.skipped` says so, and `autoSync` keeps the last real result.

## Where the code is

`packages/fespalier_cratestack/lib/src/`: `owned_rows.dart`, `lww.dart`, `hlc.dart`, `row_sync.dart`, `sync_engine.dart`,
`auto_sync.dart`, `revision.dart`. `FakeRowServer` in `lib/testing.dart` is a reference `RowSync`.
