# fespalier_storage_hive

A storage for the [`dataCache`](https://github.com/fespalier/fespalier/blob/main/docs/data.md#a-cache-on-disk-fespalier_storage) of
[fespalier](https://github.com/fespalier/fespalier) on [hive_ce](https://pub.dev/packages/hive_ce) **alone** (since the
release after 0.25.0): `HiveDataStorage`, with no shared_preferences in the app. A route's `data.dart` with a `dataCache`
is saved when it loads, and at the next start the saved value is **on the first frame** while the fresh one loads. It keeps
to a size budget, evicts the entries written longest ago, and drops what it cannot read.

It is the Hive half of [fespalier_storage](https://github.com/fespalier/fespalier/tree/main/packages/fespalier_storage),
which depends on it and re-exports `HiveDataStorage` next to `PrefsDataStorage`. Pick one:

| Depend on                | You get                                  | Plugins it brings                        |
| ------------------------ | ---------------------------------------- | ---------------------------------------- |
| `fespalier_storage_hive` | `HiveDataStorage`                        | `path_provider` (hive_ce is pure Dart)   |
| `fespalier_storage`      | `HiveDataStorage` and `PrefsDataStorage` | `path_provider` and `shared_preferences` |

A Flutter plugin's native code is in the app whenever the plugin is in its dependencies, whether or not the app calls it,
so an app that saves to Hive alone depends on this package and leaves `shared_preferences` out.

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
      ref: v0.25.0
  fespalier_storage_hive:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_storage_hive
      ref: v0.25.0
```

<!-- x-release-please-end -->

The package needs Dart 3.9 and Flutter 3.35 or newer. An app that overrides it with a `path:` (a checkout, a fork) and
also depends on `fespalier_storage` overrides both.

## Wire it

Open the storage in `startup()` and give it to `dataCacheStorage`:

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart' show dataCacheStorage;
import 'package:fespalier/startup.dart';
import 'package:fespalier_storage_hive/fespalier_storage_hive.dart';

Future<List<Override>> startup() async => [
  dataCacheStorage.overrideWithValue(await HiveDataStorage.open()),
];
```

- `open()` opens the box `fespalier_data_cache` in the app's cache directory (`directory:` for another one; IndexedDB on
  the web), returns `null` with a debug line when it cannot, and `dataCacheStorage` takes `null` as "save nothing".
- `HiveDataStorage(box)` takes a box you opened yourself (with a cipher, say).
- **Opening reads the whole box into memory**, and Hive keeps it there: `maxSize` (4,000,000 characters by default, in
  `String.length` units, keys and headers included) and `maxEntries` (1,000) bound both the memory and the startup cost.
  On a phone with little memory, lower them.
- A value too large for `maxSize` is not saved (`DataEntryTooLarge`). Expired and unreadable entries are deleted when the
  storage is made. `clear()` deletes everything this storage saved, for a sign-out; the box's other keys are never
  touched.

The debug lines start with `fespalier_storage:`, as they did before the split, so a search for them finds the same pages.

## Test it

`package:fespalier_storage_hive/testing.dart` has `memoryBox()`, a Hive box in memory (no file, no plugin), for
`HiveDataStorage(await memoryBox())`.

## A storage of your own

`package:fespalier_storage_hive/bounded.dart` is the core `HiveDataStorage` and `PrefsDataStorage` are built on:
`BoundedDataStorage`, a `Storage<String, String>` with the budget, the eviction, the sweep and the `fsc1` entry format,
over any `EntryStore` (synchronous `keys` and `get`, asynchronous `put` and `remove`). Extend it for another synchronous
store; keep every entry under `storedKeyPrefix`, and check budgets with `checkBudget`.

## Rules

- **Reads are synchronous**, so Riverpod's `persist` gives the saved value to the first build.
- **No timer, no background sweep.** The sweep runs once, when the storage is made, and is a function of the store and
  `clock.now()`.
- **One writer per box.** A background isolate that writes the same box makes the in-memory index stale until the next
  start.
- Not built: a storage-wide version key, encryption (open your own box with a cipher and pass it in), multi-isolate safety.
