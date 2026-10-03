# fespalier_storage

Storages for the [`dataCache`](https://github.com/fespalier/fespalier#a-cache-that-survives-a-restart-datacache) of
[fespalier](https://github.com/fespalier/fespalier) (since 0.9.0): `PrefsDataStorage` on shared_preferences and
`HiveDataStorage` on hive_ce. A route's `data.dart` with a `dataCache` is saved when it loads, and at the next start the
saved value is **on the first frame** while the fresh one loads. Both keep to a size budget, evict the entries written
longest ago, and drop what they cannot read. fespalier itself has no dependency on either plugin: the generated code is
the same bytes, and an app that does not depend on this package pays nothing.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
  fespalier_storage:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_storage
      ref: v0.8.1
```

<!-- x-release-please-end -->

The package needs Dart 3.8 and Flutter 3.32 or newer. `shared_preferences` and `path_provider` are flutter.dev plugins
most apps have; `hive_ce` is pure Dart (no plugin). Dart that an app does not use is not in its release build.

## Wire it

Open a storage in `startup()` and give it to `dataCacheStorage`. `open()` is awaited there, so the first frame is the
app (a `startup()` that returns a `Future` costs one frame behind `splash.dart`, and no more):

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
];
```

`open()` returns `null` (and prints a debug line) when the store cannot open, and `dataCacheStorage` takes `null` as
"save nothing": a cache never stops an app from starting. Pick `HiveDataStorage.open()` for more or larger values than
shared preferences should hold; both take `maxSize` (in `String.length` units, keys and headers included) and
`maxEntries`.

| What           | `PrefsDataStorage`                                                                    | `HiveDataStorage`                                                                             |
| -------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Backend        | `SharedPreferencesWithCache` (localStorage on the web)                                | a `hive_ce` `Box<String>` (IndexedDB on the web)                                              |
| Reads          | synchronous (a map lookup and a header parse)                                         | synchronous once the box is open                                                              |
| Default budget | 1,000,000 characters, 200 entries                                                     | 4,000,000 characters, 1,000 entries                                                           |
| Pick it when   | a few small values; the web's ~5 MB localStorage is shared with everything else there | more or larger values; opening reads the whole box, so `maxSize` also bounds the startup cost |

Over budget, the entries **written longest ago** go first (a route's value is written each time it is fetched fresh, so
what is read is rewritten), ties by key. A value too large for `maxSize` is not saved (`DataEntryTooLarge`, printed after
fespalier's `could not save`). Expired and unreadable entries are deleted when the storage is made. `clear()` deletes
everything this storage saved, for a sign-out; the app's own keys are never touched.

## Test it

```dart
setUp(fakePrefsStore); // shared_preferences in memory; two open()s in one test are a restart

testWidgets('the saved team is on the first frame of the next start', (tester) async {
  // ... boot with dataCacheStorage.overrideWithValue((await PrefsDataStorage.open())!), load, dispose,
  // then open() again and pump with settle: false: the first frame shows the saved value.
});
```

`package:fespalier_storage/testing.dart` has `fakePrefsStore([values])` and `memoryBox()` (a Hive box in memory, for
`HiveDataStorage(await memoryBox())`). Call `fakePrefsStore` before any test that boots `AppMain.root()` or `AppMain.run()`
when `startup()` opens a `PrefsDataStorage`: with no platform `open()` returns `null` and nothing is saved.

## Rules

- **Reads are synchronous**, so Riverpod's `persist` gives the saved value to the first build.
- **No timer, no background sweep.** The sweep runs once, when the storage is made, and is a function of the store and
  `clock.now()` (so a test's fake clock ages entries).
- **One writer per store.** A background isolate that writes the same store makes the in-memory index stale until the next
  start. The index is never saved, so it cannot disagree with the store across a crash.
- **`DataCache.version` stays Riverpod's `destroyKey`.** `fsc1` versions the storage format itself; to drop everything on an
  app update, call `clear()`.
- Not built: a storage-wide version key, encryption (open your own Hive box with a cipher and pass it in), multi-isolate
  safety.
