# Freshness and the data cache

Since 0.8.1. Two opt-in declarations in a `data.dart` (and, for the first, a `route.dart`): `freshness` says when a
loaded value is old enough to load again, and `dataCache` saves it for the next start. An app that writes neither
generates the same code as 0.7.0.

The app these samples build (`my_app`):

```dart
// lib/api.dart
import 'package:fespalier/fespalier.dart';

class Product {
  const Product(this.id, this.name);

  factory Product.fromJson(Map<String, Object?> json) =>
      Product(json['id']! as int, json['name']! as String);

  final int id;
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

abstract class Api {
  Future<Product> product(int id);
}

class RealApi implements Api {
  @override
  Future<Product> product(int id) async => Product(id, 'Real $id');
}

final apiProvider = Provider<Api>((ref) => RealApi());
```

## `freshness` in a `data.dart`

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/api.dart';

/// Fresh for a minute; loaded again when the app comes back to the foreground or the
/// network comes back.
const freshness = Freshness(
  staleTime: Duration(minutes: 1),
  refetchOnResume: true,
  refetchOnReconnect: true,
);

/// Saved for the next start, once main.dart gives a `dataCacheStorage`.
final dataCache = DataCache<Product>.json(
  toJson: (p) => p.toJson(),
  fromJson: (j) => Product.fromJson(j! as Map<String, Object?>),
);

Future<Product> data(Ref ref, {required int id}) =>
    ref.watch(apiProvider).product(id);
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

- **A top-level variable of exactly that name**, `const` or `final`, initialised with a `Freshness(...)` call
  (`const Freshness(...)` and `prefix.Freshness(...)` are fine). `fsp` reads the name and the call's shape, never the
  value: the generated file refers to `_iN.freshness`, and Dart type-checks it.
- **Only the function form** that returns `Future<T>`, `FutureOr<T>` or a plain `T`. A `Stream` function, a selector and
  a provider form are errors (`fespalier-troubleshooting`): wrap your own provider's value instead,
  `Future<Product> build() => freshData(ref, const Freshness(staleTime: Duration(minutes: 1)), _fetch());`.
  `freshData` returns the value itself, so a `Future` stays the `Future`.
- The generated provider is `freshData(ref, _iN.freshness, traceData(...))`; the `DevTools` wrapper stays the inner one.

### A folder's default: `route.dart`

```dart
// lib/app/teams/$teamId/route.dart
import 'package:fespalier/fespalier.dart';

/// Every data() function at and below /teams/:teamId is fresh for 30 seconds.
const freshness = Freshness(staleTime: Duration(seconds: 30));
```

```dart
// lib/app/teams/$teamId/data.dart
import 'package:fespalier/fespalier.dart';

Future<int> data(Ref ref, {required String teamId}) async => teamId.length;
```

```dart
// lib/app/teams/$teamId/page.dart
import 'package:flutter/material.dart';

class TeamPage extends StatelessWidget {
  const TeamPage({super.key, required this.teamId, required this.size});

  final String teamId;
  final int size;

  @override
  Widget build(BuildContext context) => Text('$teamId: $size');
}
```

- The **nearest** `route.dart` with a `freshness` at or above a folder applies to that folder's `data.dart`; a
  `data.dart`'s own `freshness` wins over all of them; a root `lib/app/route.dart` is the app-wide default. Sections'
  `data.dart` files are covered too.
- The cascade is a default, not a demand: a selector, a provider form or a `Stream` below is **skipped silently**. A
  `route.dart` `freshness` that covers no `data.dart` is a warning.
- There is **no `fespalier:` key** for it, on purpose: a Dart constant is type-checked and needs no duration grammar.
- `dataCache` in a `route.dart` is an error: each data type has its own encode and decode.

## When a value is stale, and what loads it

A value is stale once it has been in memory for `staleTime` **since it arrived** (the `Future` completed; for a sync
`data()`, the microtask after it was built). Loading and error values are never stale. Nothing polls: no timer starts.

| Something happens                                                                                                                   | A stale value                                   |
| ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| A **new listener**: a page opens on it, `SectionView` below a section, `watch` in a mounting widget, `prefetch`/`preload`, `read`   | shows at once, and loads again                  |
| A **listener comes back**: a page uncovered by a pop, a tab shown again (Riverpod resumes the subscription when `TickerMode` is on) | shows at once, and loads again                  |
| `refetchOnResume` and the app resumes; `refetchOnReconnect` and `reconnectSignal` fires (threshold `staleTime ?? Duration.zero`)    | loads again                                     |
| `ref.invalidate`, `XRoute.refresh`, an action's `invalidates` (**not a read**: `staleTime` has nothing to say about a write)        | loads **at once**, however long the `staleTime` |

- **Stale-while-revalidate.** The old value is on the first frame (no `Future`, no blank frame). With `keep_previous: true`
  the page stays until the new value arrives; with `false`, `loading.dart` shows meanwhile.
- **A failed reload keeps the page.** A route with a `freshness` or a `dataCache` gets `keepDataOnError: true` on its
  `DataView`, so `error.dart` only shows when there is nothing to show. The error is in `XRoute.watch(ref).error`, and
  `XRoute.refresh(ref)` completes with it. A failed user `refresh()` is therefore hidden behind the old page: show a
  snackbar from its error.
- **Every new reader counts.** A small `staleTime` makes each page that opens below a section load the section again;
  `Duration.zero` loads on every open.
- **`read` returns what is in memory**, stale or not, and starts the reload; `refresh` waits for the network.
- **`keepFor` is another thing**: how long a `PrefetchHandle` keeps a value in memory with nothing on screen. A handle
  alive across an app resume loads under `refetchOnResume` too.
- **`refetchOnResume` wants a `staleTime`**: an iOS notification shade or a browser window regaining focus is a resume
  too, and without a `staleTime` every one loads again.

### Reconnect: plug in a source

`reconnectSignal` never fires by itself (Flutter has no API for "the network is back"). Override it with a
`RefetchSignal` that listens to your source, or call `ref.read(reconnectSignal.notifier).fire()`. This one is written
against a `Stream<bool>` the app owns; with `connectivity_plus`, map its `onConnectivityChanged` to that stream.

```dart
// lib/connectivity.dart
import 'package:fespalier/fespalier.dart';

/// true while the device is online. The app provides it (connectivity_plus, say).
final onlineProvider = Provider<Stream<bool>>((ref) => const Stream.empty());

/// Fires when the device goes from offline to online.
class ConnectivitySignal extends RefetchSignal {
  @override
  int build() {
    var online = true;
    final subscription = ref.read(onlineProvider).listen((now) {
      if (now && !online) fire();
      online = now;
    });
    ref.onDispose(subscription.cancel);
    return 0;
  }
}

// main.dart: ProviderScope(overrides: [reconnectSignal.overrideWith(ConnectivitySignal.new)], ...)
final connectivityOverride = reconnectSignal.overrideWith(
  ConnectivitySignal.new,
);
```

## `dataCache`: a value for the next start

- **A top-level variable named `dataCache`**, `const` or `final`, initialised with `DataCache(...)`,
  `DataCache<T>(...)`, `DataCache.json(...)` or `DataCache<T>.json(...)`. `.json` saves `jsonEncode(toJson(v))` and reads
  `fromJson(jsonDecode(s))`; the plain constructor takes `encode` and `decode` over a `String`. `maxAge` (default 2 days)
  is how long a saved value may be shown at a start; `version` is a string you change when `encode` writes another
  shape: values of another version are dropped, not decoded.
- **Nothing is saved until the app gives a storage**: `dataCacheStorage` is `null` by default. Override it in the
  `ProviderScope`: `dataCacheStorage.overrideWithValue(MemoryDataStorage())` (in memory: a page opened again shows its
  last value; no restart), or a `Storage<String, String>` on disk. **`fespalier_storage` (since 0.9.0) is one**: `PrefsDataStorage`
  on shared_preferences or `HiveDataStorage` on hive_ce, with a size budget and eviction, in
  [`storage-backends.md`](storage-backends.md). `riverpod_sqflite`'s `JsonSqFliteStorage` plugs in as it is. To write
  your own, `import 'package:fespalier/persist.dart';` (it re-exports Riverpod's `Storage`, `PersistedData`,
  `StorageOptions` and `StorageCacheTime`). A storage whose `read` is synchronous gives the saved value on the
  **first frame**; a `Future<Storage>` costs one `loading.dart` frame. Before 0.9.0 the docs showed a hand-written
  `PrefsStorage` over `SharedPreferencesWithCache` here; the package is that, tested, with a budget, eviction, an
  unreadable-entry rule and `open()` that never throws.
- **Built on Riverpod 3's experimental offline persistence** (`persist()`), in one runtime file
  (`packages/fespalier/lib/src/data_cache.dart`). A Riverpod 3.x minor could change that API.
- **The state at a start** is `AsyncLoading(value: saved)` with `isFromCache == true` and the fetch already running.
  `DataView` shows it whatever `keep_previous` says. A success replaces it and saves; **a failure keeps the page and the
  saved value** (Riverpod's own `persist` deletes it on any error; fespalier guards that, so an offline start shows the
  last data, and so does the next one, until `maxAge`). A value that does not decode is dropped, never reported as an
  error. A cold start always loads again, whatever the `staleTime`.
- **Keys**: `fespalier:<folder>` plus the route's keys in path order as JSON (`fespalier:products/$id[42]`). An enum key
  is saved by `name`, a `DateTime` as ISO 8601, a list as a list, anything else by `toString()`: keep a custom segment
  type's `toString()` stable (a minified web build would change it).
- **Debug-only lines** (`debugPrint`):
  `fespalier: dataCache of <name> could not read a saved value, dropped it: <error>` and
  `fespalier: dataCache of <name> could not save: <error>`.
- **Do not write an optimistic value with `state =`** on this provider's notifier: every `AsyncData` it sets is saved.

## Tests

`testWidgets` runs in fake async and `clock.now()` is its clock, so aging data costs no time and starts no timer. Nothing
persists unless the test overrides `dataCacheStorage`; share one `MemoryDataStorage` between two `pumpRouter` calls for a
restart.

```dart
// test/freshness_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/api.dart';
import 'package:my_app/app.g.dart';

class CountingApi implements Api {
  var loads = 0;
  var offline = false;

  @override
  Future<Product> product(int id) async {
    loads++;
    if (offline) throw StateError('offline');
    return Product(id, 'Product $id v$loads');
  }
}

Future<ProviderContainer> open(
  WidgetTester tester,
  Api api, {
  MemoryDataStorage? storage,
}) => pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/products/1'),
  overrides: [
    apiProvider.overrideWithValue(api),
    if (storage != null) dataCacheStorage.overrideWithValue(storage),
  ],
);

void main() {
  testWidgets('a resume loads a stale product again, a fresh one not', (
    tester,
  ) async {
    final api = CountingApi();
    await open(tester, api);
    expect(find.text('Product 1 v1'), findsOneWidget);

    Future<void> resume() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    await tester.pump(const Duration(seconds: 20));
    await resume();
    expect(api.loads, 1);
    await tester.pump(const Duration(minutes: 2));
    await resume();
    expect(api.loads, 2);
    expect(find.text('Product 1 v2'), findsOneWidget);
  });

  testWidgets('a reconnect follows the same rule', (tester) async {
    final api = CountingApi();
    final container = await open(tester, api);
    container.read(reconnectSignal.notifier).fire();
    await tester.pumpAndSettle();
    expect(api.loads, 1);
    await tester.pump(const Duration(minutes: 2));
    container.read(reconnectSignal.notifier).fire();
    await tester.pumpAndSettle();
    expect(api.loads, 2);
  });

  testWidgets('an invalidation loads at once, whatever the staleTime', (
    tester,
  ) async {
    final api = CountingApi();
    final container = await open(tester, api);
    container.invalidate(ProductRoute.data(1));
    await tester.pumpAndSettle();
    expect(api.loads, 2);
  });

  testWidgets('a restart shows the saved product when the network is down', (
    tester,
  ) async {
    final storage = MemoryDataStorage();
    await open(tester, CountingApi(), storage: storage);
    expect(find.text('Product 1 v1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await open(tester, CountingApi()..offline = true, storage: storage);
    expect(find.text('Product 1 v1'), findsOneWidget);
  });
}
```

- A resume is `handleAppLifecycleStateChanged(inactive)` then `(resumed)`, or
  `container.read(appResumeSignal.notifier).fire()`.
- A pure `ProviderContainer` test of a `refetchOnResume` provider, with no `WidgetsBinding`, throws when the signal is
  built: use `testWidgets`, or override `appResumeSignal.overrideWith(RefetchSignal.new)`.
- A reload starts on a frame and its value shows on the next: `pump()` a few times, or `pumpAndSettle` when nothing waits
  on a real delay.
- `await tester.pump(const Duration(days: 3))` expires a `MemoryDataStorage` value under the fake clock.
- A restart on disk (since 0.9.0): `fakePrefsStore()` in `setUp`, then two `PrefsDataStorage.open()`s in one test
  (`storage-backends.md`).
