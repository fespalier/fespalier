# Reads: `ref.serve`, `Served` and `ReadCache`

Since 0.10.0. `ref.serve` is an extension on `Ref` (`CrateStackServeRef`): it runs a read under a **policy**, saves a
network answer for the current account, and on a connection failure serves the saved one. It returns a
`FutureOr<Served<T>>`, so a `data.dart` that uses it is a function-form `data()` like any other.

```dart
// lib/catalog.dart
import 'package:fespalier/fespalier.dart';

abstract class CatalogApi {
  Future<List<String>> names();
}

final catalogApi = Provider<CatalogApi>((ref) => throw UnimplementedError('override catalogApi in startup()'));
```

```dart
// lib/app/catalog/data.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:my_app/catalog.dart';

final _codec = ServedCodec<List<String>>(
  version: '2', // change it when the saved shape changes: old answers are dropped
  toJson: (names) => names,
  fromJson: (json) => [for (final name in json! as List<Object?>) name! as String],
);

/// Names that do not change once saved: the device first, the server only when there is nothing.
FutureOr<Served<List<String>>> data(Ref ref) => ref.serve(
  key: 'catalog:names', // the saved answer's key, per account
  tag: 'catalog', // the revision tag a sync or an accepted intent bumps; defaults to the key's prefix before ':'
  codec: _codec,
  policy: ReadPolicy.cacheFirst,
  empty: () => const [],
  maxAge: const Duration(days: 1),
  fetch: () => ref.read(catalogApi).names(),
);
```

```dart
// lib/app/catalog/page.dart
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';

class CatalogPage extends StatelessWidget {
  const CatalogPage(this.names, {super.key});

  final Served<List<String>> names;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (names.stale) Text('As of ${names.fetchedAt}, refresh when you are online'),
      for (final name in names.value) Text(name),
    ],
  );
}
```

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart' show dataCacheStorage;
import 'package:fespalier/startup.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_storage/fespalier_storage.dart';

Future<List<Override>> startup() async {
  // Intents and rows must never be evicted, so they live in a LocalStore. In an app this is
  // HiveLocalStore.open(directory: ...) (see fespalier-cratestack); in memory it loses them at exit.
  final store = InMemoryLocalStore();
  // open() is null when shared preferences could not open: the app starts and the reads are not saved.
  final prefs = await PrefsDataStorage.open();
  return [
    localStore.overrideWithValue(store),
    // Optional: saved reads in the storage your dataCache already uses, with their key list in the durable store,
    // so a sign-out can wipe them and nothing evicts the list.
    if (prefs != null) readCache.overrideWithValue(ReadCache.storage(prefs, index: store)),
    if (prefs != null) dataCacheStorage.overrideWithValue(prefs),
  ];
}
```

## `serve`'s parameters

| Parameter | Meaning                                                                                                                                                  |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `key`     | The saved answer's name, **per account**. Required                                                                                                       |
| `codec`   | `ServedCodec(toJson:, fromJson:, version: '1')`: JSON like `DataCache.json`. A saved answer that no longer decodes, or has another `version`, is dropped |
| `fetch`   | The call. Required unless the policy is `localOnly`: `ArgumentError: fespalier_cratestack: serve needs a fetch unless the policy is localOnly`           |
| `policy`  | `networkFirst` (default), `cacheFirst`, `localOnly`, `serverOnly`                                                                                        |
| `empty`   | The value for "nothing saved" **for a list**; without it a miss throws `CrateStackNoLocalData(<key>)`                                                    |
| `maxAge`  | Drives `Served.stale`; null means never stale                                                                                                            |
| `tag`     | The `crateStackRevision` tag the read watches, so a sync or an accepted intent that `touches` it makes the read run again                                |

`serve` also **watches `crateStackScope`** (a sign-in change rebuilds the read) and the revision of its tag.

## `Served<T>`

`value`, `source` (`ServedFrom.network` or `ServedFrom.local`), `fetchedAt` (when the server last answered this read for
this account, on this device; null when never), `stale` (older than `maxAge`) and `neverFetched` (no `fetchedAt`). It
is named `Served` so it does not clash with fespalier's `Freshness`.

## Where the answer comes from

- `networkFirst` and `serverOnly` call `fetch` and save the value with `fetchedAt = clock.now()`. Only a
  **`CrateStackOffline`** falls back (not for `serverOnly`, where it is thrown): the saved answer, else `empty()`
  (`neverFetched`), else `CrateStackNoLocalData`. A refusal, or an error no reader in `crateStackErrors` knows, is
  rethrown as it is.
- `cacheFirst` returns the saved answer when there is one, else behaves like `networkFirst`.
- `localOnly` never calls `fetch`: for data this device saves itself (rows it owns are read from `ownedRows`).
- **The save is skipped** for an account that signed out, or a read that was rebuilt, while the call was in the air, so
  a sign-out wipe stays done. A save that fails is a missing cache, printed in debug as
  `fespalier_cratestack: could not save the read <key>: <error>`.
- **Sync stays sync.** With `localOnly`, or `cacheFirst` with a hit, on a store that answers synchronously (the
  in-memory store, Hive, `PrefsDataStorage`) `serve` returns a `Served`, not a `Future`: the saved copy is on the first
  frame. A `Future` store costs one `loading.dart` frame.
- **What counts as offline** is `CrateStackErrors.classify`: your reader for the generated client's exception, then
  `DioFailures.read` (connection errors and timeouts, `text/html`, a bare `502`, `503`, `504`, `511`; a bare `500` is
  `CrateStackUnavailable`, not offline; a certificate that does not verify is unknown, not offline).

## `ReadCache`

`readCache` is `ReadCache.local(localStore)` by default (under the account's prefix, so a sign-out's `clear` takes it).
`ReadCache.storage(storage, index: store)` puts the answers on the storage your `dataCache` already opens; pass
`index:` (the durable `LocalStore`) so the list of an account's keys, which a sign-out needs to wipe them, cannot be
evicted. A budgeted storage may evict an answer: that is a miss, harmless for a cache.

## Where the code is

`packages/fespalier_cratestack/lib/src/served.dart` (`serve`, `ReadPolicy`, `ServedCodec`, `Served`),
`read_cache.dart`, `errors.dart` (`CrateStackFailure.fromResponse`) and `dio/failures.dart`.
