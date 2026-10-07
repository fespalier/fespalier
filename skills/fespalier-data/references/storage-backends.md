# `fespalier_storage`: a cache on disk

Since 0.9.0. [`dataCache`](freshness-and-cache.md) saves a route's value only when the app gives it a `dataCacheStorage`.
`package:fespalier_storage` is a tested `Storage<String, String>` on **shared_preferences** (`PrefsDataStorage`) or **Hive**
(`HiveDataStorage`), with a size budget, so the saved value is **on the first frame** of the next start. It changes no
generated code and adds no file kind, key or command; an app that does not depend on it pays nothing.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_storage:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_storage
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves the pair only at a release tag. `docs/data.md` has the annotated block.)

## Which one

| What           | `PrefsDataStorage`                                                          | `HiveDataStorage`                                                                    |
| -------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Backend        | `SharedPreferencesWithCache`; localStorage on the web                       | a `hive_ce` `Box<String>`; IndexedDB on the web                                      |
| Reads          | synchronous                                                                 | synchronous once the box is open                                                     |
| Default budget | `maxSize` 1,000,000 characters, `maxEntries` 200                            | `maxSize` 4,000,000 characters, `maxEntries` 1,000                                   |
| Plugins        | `shared_preferences` (most apps have it)                                    | none (`hive_ce` is pure Dart); `path_provider` for the cache directory               |
| Pick it when   | a few small values (SharedPreferences is not meant for large ones); the web | more or larger values; opening reads the whole box, so `maxSize` also bounds startup |

`PrefsDataStorage.open()` creates its own `SharedPreferencesWithCache` with **no allowList** (the keys of a `dataCache` are not
known in advance), which caches all of the app's preferences in memory a second time: the size of the app's prefs. An app that
minds passes its own instance to `PrefsDataStorage(prefs)`; with an allowList that is an `ArgumentError` (S6).
`HiveDataStorage.open()` passes a per-box `path:` from `getApplicationCacheDirectory()` (the OS may purge it, and it is not
backed up), so it never moves an app's own Hive home; on the web the path is none. It depends on `hive_ce` only, not
`hive_ce_flutter` (which needs Flutter 3.44 or newer): an app that opens its own box passes it to `HiveDataStorage(box)`, and
may give that box a cipher.

## The starter

A product page with a `dataCache`, a `startup()` that opens the storage, and a restart test on each storage. The scratch
app's own `HomePage` is at `/`.

```dart
// lib/api.dart
import 'package:fespalier/fespalier.dart';

class Product {
  const Product(this.id, this.name);

  final int id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static Product fromJson(Object? json) {
    final map = json! as Map<String, Object?>;
    return Product(map['id']! as int, map['name']! as String);
  }
}

abstract interface class Api {
  Future<Product> product(int id);
}

class OnlineApi implements Api {
  const OnlineApi();

  @override
  Future<Product> product(int id) async => Product(id, 'Product $id');
}

final apiProvider = Provider<Api>((ref) => const OnlineApi());
```

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/api.dart';

/// Saved for the next start (see startup.dart): it shows at once while the product loads again, and when it can't.
final dataCache = DataCache<Product>.json(
  toJson: (p) => p.toJson(),
  fromJson: Product.fromJson,
  version: '1',
);

Future<Product> data(Ref ref, {required int id}) => ref.watch(apiProvider).product(id);
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/api.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) => Text(product.name);
}
```

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart' show dataCacheStorage;
import 'package:fespalier/startup.dart';
import 'package:fespalier_storage/fespalier_storage.dart';

/// The storage is open before the first frame, so a saved product is on it. `open()` is null if shared preferences
/// could not open (a debug line says why): the app starts and nothing is saved. For Hive, `await HiveDataStorage.open()`.
Future<List<Override>> startup() async => [
  dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
];
```

```dart
// test/offline_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart' show Storage;
import 'package:fespalier/testing.dart';
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:fespalier_storage/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/api.dart';
import 'package:my_app/app.g.dart';

class OfflineApi implements Api {
  @override
  Future<Product> product(int id) async => throw StateError('offline');
}

Future<void> open(WidgetTester tester, Storage<String, String> storage, {Api? api, bool settle = true}) => pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/products/1'),
  overrides: [
    dataCacheStorage.overrideWithValue(storage),
    if (api != null) apiProvider.overrideWithValue(api),
  ],
  settle: settle,
);

void main() {
  // shared_preferences in memory; two open()s in one test share it: that is a restart.
  setUp(fakePrefsStore);

  testWidgets('the saved product is on the first frame of the next start', (tester) async {
    await open(tester, (await PrefsDataStorage.open())!);
    expect(find.text('Product 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // the restart
    await open(tester, (await PrefsDataStorage.open())!, api: OfflineApi(), settle: false);
    // One frame, nothing settled: the product is there, not loading.dart.
    expect(find.text('Product 1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Product 1'), findsOneWidget, reason: 'the load failed, the saved value stays');
  });

  testWidgets('the same on Hive, in memory', (tester) async {
    final box = await memoryBox();
    addTearDown(box.close);
    await open(tester, HiveDataStorage(box));
    expect(find.text('Product 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await open(tester, HiveDataStorage(box), api: OfflineApi(), settle: false);
    expect(find.text('Product 1'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('clear() is a sign-out: the next start shows nothing', (tester) async {
    final storage = (await PrefsDataStorage.open())!;
    await open(tester, storage);
    await storage.clear();

    await tester.pumpWidget(const SizedBox());
    await open(tester, (await PrefsDataStorage.open())!, api: OfflineApi());
    expect(find.text('Product 1'), findsNothing);
  });
}
```

## Behaviour to rely on

- **Open and first frame.** `open()` creates the store, builds the storage (its sweep deletes what expired or cannot be
  read, and counts it), awaits those deletes and returns it. From then on `read` is a map lookup and a header parse, so
  Riverpod's `persist` gets the saved value synchronously in `CachedData.build`, and the first frame is `isFromCache`.
  `await` it in `startup()` (one splash frame); passing the `Future` itself costs one `loading.dart` frame, then the saved
  value.
- **A storage that cannot open is `null`, never a throw.** `PrefsDataStorage.open()` and `HiveDataStorage.open()` print a
  debug line (S4, S5) and `dataCacheStorage` takes `null` as "save nothing": a `startup()` that threw would show the
  splash's error, and a cache must not stop the app. A budget of 0 is the exception: it is the app's mistake, an
  `ArgumentError` (S7).
- **The entry** is one string under the key `fespalier.dataCache/` plus the dataCache key: five header lines (`fsc1`,
  expiry, write time, `destroyKey`, the original key when the key was hashed) and the data, never parsed twice (so the web's
  localStorage does not hold the JSON escaped a second time). A Hive key over 255 UTF-8 bytes is stored under the SHA-256 of
  the key, with the key in the header: a collision is a miss, not corruption.
- **Eviction is deterministic**: over `maxSize` or `maxEntries`, the entry **written longest ago** goes first, ties by key,
  never the one just written. A route's value is written each time it is fetched fresh, so what is read is rewritten;
  reads never write. `size` is `String.length` units (UTF-16 code units: what browsers count localStorage in), keys and
  headers included. An entry too large for `maxSize` is not saved and its older copy is removed (S1, printed after fespalier's
  `could not save`).
- **The sweep runs once, when the storage is made** (Riverpod's `Storage` constructor calls `deleteOutOfDate()`): expired and
  unreadable entries are deleted, then the budgets are applied (so a lowered budget evicts at the next start). No timer, no
  background work. The in-memory index is built then and never saved, so it cannot disagree with the store across a crash.
- **Versioning.** `DataCache(version: '2')` is Riverpod's `destroyKey`: stored in the header, compared on read, and a
  mismatch is deleted, not decoded. `fsc1` versions the storage format: a later `fsc2` is read as unreadable by `fsc1`
  code, which for a cache means "dropped and loaded again". To drop everything on an app update, call `clear()`.
- **Corruption.** An unreadable entry is counted and dropped at start (S3), and at a read it is a `FormatException` (S2)
  that fespalier prints (`dropped it`) and deletes. Hive truncates a corrupt frame when it opens a box
  (`crashRecovery`). Nothing reaches the app's startup.
- **Sign-out.** `clear()` deletes every entry this storage saved (and any unreadable one under its prefix), and nothing else:
  the app's own preferences and the other keys of a shared Hive box are never touched. Call it on sign-out, so the next
  start shows nothing from the previous user, and watch `authUserId` in a `data.dart` whose data belongs to the user.
- **The web.** localStorage is about 5 MB per origin, shared with everything else there: keep `PrefsDataStorage`'s `maxSize` well
  below it. A full one is a `QuotaExceededError` on the write; the entry is dropped and fespalier prints `could not save`. Use
  Hive (IndexedDB) for a larger cache.
- **One writer per store.** A background isolate or a package like `workmanager` that writes the same store makes the index stale
  until the next start.

## Traps

- **`open()` in a test with no `fakePrefsStore()` is `null`**, silently apart from a debug line: the cache is off and a
  restart test shows `loading.dart`. `setUp(fakePrefsStore)`, also before a test that boots `AppMain.run()` or
  `AppMain.root()` (the app's `startup()` opens one).
- **`HiveDataStorage.open()` needs the `path_provider` plugin**, which a widget test does not have: it returns `null` and prints
  `MissingPluginException(...)` (S5). Use `HiveDataStorage(await memoryBox())` in tests.
- **A platform channel call needs the real event loop.** If a test of your own awaits a plugin (`path_provider`), wrap it in
  `tester.runAsync`; the in-memory fakes of this package complete under `testWidgets`' fake async.
- **A `SharedPreferencesWithCache` with an allowList** given to `PrefsDataStorage(prefs)` throws (S6); use `open()`.
- **Not for secrets.** A `dataCache` is not encrypted; tokens go in `fespalier_auth`'s secure store.
- **A value is not shown after a `version` change, or after `maxAge`**: by design (deleted, not decoded). `maxAge` defaults to
  two days.
- **Not built:** a storage-wide version key, a byte-exact size, multi-isolate safety, encryption (open your own Hive box with a
  cipher and pass it in).

The messages are in [`fespalier-troubleshooting`](../../fespalier-troubleshooting/SKILL.md) (its
`diagnostics-flags-storage-network.md` page). `examples/features` keeps its team in shared preferences, with
`test/offline_test.dart`.
