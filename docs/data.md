# Data

## `data.dart`: a function, a selector or a provider

`data.dart` has three forms, told apart by what it exports:

| You write                                                                                                                                | fespalier                                                                     | Use it when                                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `Future<T> data(Ref ref, {…})` (or `Stream<T>`, or `T`)                                                                                  | wraps it in an autoDispose `FutureProvider` (`StreamProvider` for a `Stream`) | the data is fetched for this route only: the function is the fetch                                       |
| `ProviderListenable<AsyncValue<T>> data({…}) => productProvider(id)`                                                                     | calls it and uses the provider it returns; nothing is wrapped                 | a provider for it already exists, above all a `riverpod_generator` one                                   |
| `final data = FutureProvider<T>(…)` (or `StreamProvider`, `AsyncNotifierProvider`, `StreamNotifierProvider`), type arguments spelled out | uses it as-is                                                                 | you want to write the provider yourself (a notifier, `keepAlive`, `retry:`) and it belongs to this route |

**Selecting a provider.** If a provider for the data already exists, select it:

```dart
// lib/app/products/$productId/data.dart
ProviderListenable<AsyncValue<ProductView>> data({required String productId}) =>
    productProvider(productId);   // a generated family, a FutureProvider.family, ...
```

Don't write `Future<Product> data(Ref ref, …) => ref.watch(productProvider(id).future)` instead. That puts a second provider in front of the real one, and awaiting `.future` in it drops the error the real provider holds while it retries, so the route can't show `error.dart` during the retry window.

- **The return type says so.** `ProviderListenable<AsyncValue<T>>` with no `Ref` parameter (the function returns the provider, it doesn't read one). `T` is what the page's parameter is matched to by type, as with `Future<T>`. It is a syntax-only read: a generated provider's own type, like `ProductFamily`, isn't resolved. `ProviderListenable` comes from `package:fespalier/fespalier.dart`.
- **Parameters are the function form's.** Named parameters are segments and query parameters, keyed and typed as in `data(Ref ref, {…})`. Any other parameter, a positional one or a `Ref` is an error at that parameter.
- **`XRoute.data` is the selected provider** (`ProductDetailRoute.data('x') == productProvider('x')`), and `watch`, `read`, `prefetch` and `refresh` all go to it. The generated `DataView` watches it directly: no wrapper, no `.future` hop, one fetch per navigation. `refresh` (and `error.dart`'s `retry`) invalidates the selected provider and reads it again, so it runs once.
- **The app's provider keeps its own `retry`, `keepAlive` and dependencies**, so [`data_retry`](#retries-and-reloads) doesn't apply to it (it only configures the providers fespalier creates). `keep_previous` does, because it is about what the view shows. The app's `ProviderScope(retry: …)` applies unless the provider sets its own.
- **Refresh needs a provider, not just a listenable.** The runtime checks what it gets (a `ProviderOrFamily` with a `.future`, which every `FutureProvider`, `StreamProvider` and generated async provider is). Returning something else, say `productProvider(id).select(…)`, builds and watches fine, but `refresh` and `retry` throw a `StateError` that says to return the provider itself.
- A section's `data.dart` can be a selector too, and takes segments and query parameters like a page's.

In all three forms the route exposes the provider as `XRoute.data`, keyed by the segments and query parameters `data.dart` uses:

| Parameters used | Provider                              | Watch it with                                   |
| --------------- | ------------------------------------- | ----------------------------------------------- |
| none            | plain                                 | `ref.watch(ProductsRoute.data)`                 |
| one             | `.family<T, int>`                     | `ref.watch(ProductRoute.data(42))`              |
| several         | `.family<T, ({String shop, int id})>` | `ref.watch(ItemRoute.data((shop: 'a', id: 1)))` |

A family provider you write yourself follows the same rule for segments: with several, its argument is a record naming the ones it uses, e.g. `({String shop, int id})`. It can't be keyed by a query parameter (a record field that isn't a segment is an error). To key by one, write the function form (`Future<T> data(Ref ref, {int? page})`) or select your provider with a `data()` that takes it.

To see a scaffolded `error.dart` and its retry, throw from `data.dart`, e.g. `throw Exception('offline')`.

### Retries and reloads

Two settings in the `fespalier:` section of `pubspec.yaml` decide what a route shows while its `data.dart` fails or loads again:

```yaml
fespalier:
  data_retry: inherit # inherit | none
  keep_previous: true # true | false
```

**`keep_previous: true` (the default).** `loading.dart` is only for the first load. Once the provider has a value or an error, a reload (`ref.invalidate`, `refresh`, the section's dependencies changing) keeps rendering it: the old page stays until the new value arrives, instead of blinking to `loading.dart` and back, and `error.dart`'s `retry` keeps the error up until the new run answers. This is `skipLoadingOnReload` and `skipLoadingOnRefresh` of Riverpod's `AsyncValue.when`, for a route's `data.dart` and a section's, your own providers included. With `false`, `loading.dart` shows whenever the provider is loading, except while a write whose [`optimistic()`](actions.md#optimistic-updates-optimistic) patched the data settles (since 0.8.1).

**`data_retry: inherit` (the default).** Riverpod 3 retries a failed provider on its own, with backoff, and the app's `ProviderScope(retry: ...)` or `ProviderContainer(retry: ...)` decides how. The providers fespalier generates for `data()` functions don't set their own policy, so the app's applies (Riverpod's own default, 10 retries with doubling delays and none for an `Error`, when the app sets none). To have a failure settle into `error.dart` after a few attempts:

```dart
ProviderScope(
  retry: (retryCount, error) => retryCount < 3 ? const Duration(seconds: 1) : null,
  child: …,
)
```

A provider you write yourself always follows the app's policy, or its own `retry:`.

A provider that failed and is being retried is `AsyncLoading` with its error still held. With `keep_previous` on, `DataView` shows that error, not `loading.dart`, for the whole retry window: `error.dart` shows as soon as `data.dart` fails, retrying or not. It goes to the data when a retry succeeds, and stays on the error when the policy gives up. With `keep_previous: false` a retry shows `loading.dart` again.

**`data_retry: none`.** Every generated `data()` provider gets `retry: (retryCount, error) => null`, whatever the app's policy is: a failure is final until `error.dart`'s `retry` runs it again.

**A route with a `freshness` or a `dataCache`** (since 0.8.1) keeps its data when a reload fails, whatever `keep_previous` says: `error.dart` only shows when there is nothing to show (see [Freshness](#freshness-staletime-resume-and-reconnect)). And `DataView` shows a value that Riverpod's offline persistence restored (`isFromCache`) while the fresh one loads, with `keep_previous: false` too.

### Freshness: `staleTime`, resume and reconnect

Since 0.8.1 a `data.dart` can say when its value is old enough to load again. It is opt in: a route without the declaration loads once and keeps the value for as long as something watches it.

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:shop/api.dart';

/// Fresh for a minute; loaded again when the app comes back to the foreground.
const freshness = Freshness(
  staleTime: Duration(minutes: 1),
  refetchOnResume: true,
);

Future<Product> data(Ref ref, {required int id}) =>
    ref.watch(apiProvider).product(id);
```

`freshness` is a top-level `const` or `final` variable of exactly that name, initialized with a `Freshness(...)` call (`const Freshness(...)` and `prefix.Freshness(...)` are fine). fsp does not read the duration: the generated file refers to `_i13.freshness`, and the Dart analyzer checks it. It applies to the **function form** returning a `Future<T>`, a `FutureOr<T>` or a plain `T`; in a `data.dart` that returns a `Stream`, selects a provider or exports its own `data` provider it is an error that says what to do instead.

**A folder's default.** The same constant in a `route.dart` is the default of every `data()` function at and below that folder (a [section's](#section-data) included). The nearest `route.dart` wins, and a `data.dart`'s own `freshness` wins over all of them. A root `lib/app/route.dart` is the app-wide default.

```dart
// lib/app/teams/$teamId/route.dart
import 'package:fespalier/fespalier.dart';

/// Every data() function at and below /teams/:teamId is fresh for 30 seconds.
const freshness = Freshness(staleTime: Duration(seconds: 30));
```

The cascade is a default, not a demand: a selector, a provider form or a `Stream` below is skipped without a word. A `route.dart` whose `freshness` applies to no `data.dart` is a warning.

**What "stale" means.** A value is stale once it has been in memory for `staleTime` since it _arrived_ (the `Future` completed; for a synchronous `data()`, the microtask after it was built). A loading value or an error is never stale: Riverpod's retry and `error.dart`'s retry handle those. Nothing polls, and stale data on screen stays as it is until something reads it. A stale value is loaded again **when something reads it**:

1. **A new listener.** A page opening on it (`DataView`), a `SectionView` of a page that opens below a section, `XRoute.watch` in a widget that mounts, `prefetch` / `preload` / `AppRoutes.preload`, a [`RouteLink`](navigation.md#preloading-the-data-behind-a-link) preloading on hover, `XRoute.read`.
2. **A listener coming back.** A page uncovered by a pop, a tab shown again: Flutter turns `TickerMode` back on, and Riverpod resumes the subscription.
3. **A signal**, with `refetchOnResume` or `refetchOnReconnect` (below).

The stale value shows **at once** (no `Future`, no blank frame), and the new one replaces it (stale-while-revalidate). With `keep_previous: true` the old page stays until the new value arrives; with `false` `loading.dart` shows while it loads. If the load fails, the page **keeps its data** (see `keepDataOnError`, below), the error is in `XRoute.watch(ref).error`, and `XRoute.refresh(ref)` completes with it.

Things to know:

- **Every new reader counts.** With a small `staleTime`, a section's data loads again each time a page below it opens, because that page's `SectionView` is a new listener. `Duration.zero` loads on every open, and a prefetch is then only a head start for the first paint.
- **`read` returns what is in memory**, stale or not, and starts the reload. Use `refresh` for a value that is surely fresh: it waits for the network.
- **An invalidation is not a read.** `ref.invalidate`, `XRoute.refresh` and an [`action.dart`](actions.md#actiondart-typed-writes)'s `invalidates` load at once, whatever the `staleTime`.
- **`keepFor` is another thing.** `prefetch(ref, keepFor: …)` is how long a handle keeps a value in memory with nothing on screen; `staleTime` is how long it counts as fresh. With a ten minute `keepFor` and a one minute `staleTime`, opening the page five minutes later shows the kept value at once and loads it again. A handle still alive across an app resume loads under `refetchOnResume` too; `staleTime` bounds that.

**Resume and reconnect.** `refetchOnResume: true` loads the value again when the app returns to the foreground (`AppLifecycleListener.onResume`), `refetchOnReconnect: true` when `reconnectSignal` fires. Both use the threshold `staleTime ?? Duration.zero`: without a `staleTime` every signal loads again, so set one with `refetchOnResume` unless every focus should reload (an iOS notification shade or a regained browser focus is a resume too). Each signal is a Riverpod provider holding a count, a `RefetchSignal`, that the data provider listens to:

- `appResumeSignal` fires on resume. It is created only while a provider with `refetchOnResume` listens to it, and its `AppLifecycleListener` goes with it.
- `appShowSignal` (since 0.13.0) fires when the app is shown again after being hidden (`AppLifecycleListener.onShow`: the background or a minimised window), and **not** when it only went inactive and back (an iOS notification shade or Control Center, a call banner, a system sheet), which `appResumeSignal` does. `fespalier_biometrics` relocks on it. Same rules: created only while something listens, its listener goes with it, and a test without a binding overrides it with `appShowSignal.overrideWith(RefetchSignal.new)`.
- `reconnectSignal` **never fires by itself**: Flutter has no API for "the network is back". Override it with a `RefetchSignal` of your own that listens to your connectivity source, or call `ref.read(reconnectSignal.notifier).fire()` where you know. `fespalier_connectivity` (since 0.9.0, [below](#reconnects-fespalier_connectivity)) is that signal from `connectivity_plus`: `reconnectSignal.overrideWith(ConnectivitySignal.new)` in `startup()`.

**Your own provider.** `freshData(ref, const Freshness(...), value)` is what the generated provider wraps its value in. It returns `value` itself (a `Future` stays the `Future`, a value stays a value), so a selector's target or a provider-form `data.dart` can give itself the same rules: `Future<Product> build() => freshData(ref, const Freshness(…), _fetch());`.

**A failed reload keeps the page.** A route whose `data.dart` has a `freshness` or a `dataCache` (or inherits one) gets `keepDataOnError: true` on its `DataView`: a reload that fails (a stale value loaded again, a start offline) leaves the page on its data, and `error.dart` only shows when there is nothing to show. **A refusal is never kept (since 0.13.1):** an error that implements `DataRefusal` (core's marker for "the server decided"; `CrateStackRefused` of `fespalier_cratestack` and `AuthRejected` of `fespalier_auth` do) shows `error.dart` instead of the page, because the person may no longer be allowed to see it. Any refusal does, a 404, 429 or 400 included (`CrateStackRefused` is every `4xx` but 401 and 409). `AuthRejected` counts only when it reaches the read unwrapped: Dio wraps it in a `DioException`, and a 401 whose refresh failed arrives as `CrateStackUnauthenticated`, which keeps the page. `error.dart` gets no copy of the old value. Implement `DataRefusal` on your own error type to get the same. The cost: a failed `refresh()` is hidden behind the old page. It completes with the error (show a snackbar), and `XRoute.watch(ref).hasError` is there for a banner.

**Testing.** `testWidgets` runs in fake async and ages data by `clock.now()`, so `await tester.pump(const Duration(minutes: 6))` makes a value stale without waiting and without a timer.

- A resume is `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive)` and then `.resumed`, or `container.read(appResumeSignal.notifier).fire()` (the container is what `pumpRouter` returns). A reconnect is `container.read(reconnectSignal.notifier).fire()`.
- A test that builds a `refetchOnResume` provider in a bare `ProviderContainer`, with no binding, throws when the signal is built: use `testWidgets`, or override `appResumeSignal.overrideWith(RefetchSignal.new)`.
- A reload starts on a frame and its value shows on the next, so `pump()` a few times (or `pumpAndSettle` when nothing waits on a real delay).

**Diagnostics.** Errors that say what to write instead: a `freshness` that is not a `Freshness(...)` call, a second one, one in a `data.dart` that returns a `Stream`, selects a provider or exports its own `data` provider, and a `dataCache` in a `route.dart` ([messages](../skills/fespalier-troubleshooting/references/diagnostics-data-and-hooks.md)). `freshness` and `dataCache` are names fsp reads in a `data.dart`: a public top-level variable of one of those names with another type gets the first error, so rename it (a private `_freshness` is never read).

### Reconnects: fespalier_connectivity

Since 0.9.0. `refetchOnReconnect: true` waits for [`reconnectSignal`](#freshness-staletime-resume-and-reconnect), which never fires by itself. `package:fespalier_connectivity` is that signal, from `connectivity_plus`, with two platform repairs and a `hasNetwork` provider for an offline banner. It takes `connectivity_plus` `>=6.0.1 <8.0.0`; add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_connectivity:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_connectivity
      ref: v0.15.0
```

<!-- x-release-please-end -->

One line in `startup()`, which stays synchronous (no first-frame cost):

```dart
// lib/app/startup.dart
List<Override> startup() => [reconnectSignal.overrideWith(ConnectivitySignal.new)];

// lib/app/teams/$teamId/route.dart: every data() at and below is loaded again when the device gets a network back,
// if its value is at least 30 seconds old
const freshness = Freshness(staleTime: Duration(seconds: 30), refetchOnReconnect: true);
```

**What fires and what does not.** `ConnectivitySignal` fires when the device goes **from no network to a network** (`[none]` to anything else), not on the first answer and not on a Wi-Fi to mobile switch. Every data provider that listens loads again if its value is at least `staleTime` old (the old value stays on screen, and `keepDataOnError` keeps the page if the reload fails); within `staleTime` nothing loads. A reload already under way is not repeated, so a flapping network needs no debounce: it fires each time and loads once. The signal, and its subscription to `connectivity_plus`, exist only while a `data.dart` with `refetchOnReconnect` is alive.

**A banner.** `hasNetwork` is a `bool` provider: `false` only once the device has said "no network", and `true` before the first answer, so nothing flashes offline at start. It pairs with `XRoute.watch(ref).isFromCache` ("offline copy"):

```dart
if (!ref.watch(hasNetwork)) const Text('No network')
```

`networkConnectivity` is the `List<ConnectivityResult>?` behind it (null until the first answer), for an app that shows the kind of network.

**Connectivity versus reachability.** This package, like `navigator.onLine` on the web, answers "is a network interface up?". Only a request tells whether the server answers: a captive portal, a router with no uplink, a VPN that is down or a dead server all look connected. So `refetchOnReconnect` can fire on a captive portal (the reload fails and `keepDataOnError` keeps the page); `hasNetwork == false` is reliable ("no network at all") and `true` promises nothing, so an offline banner should say "No network" and a failed load should show its own error. fespalier ships no reachability check (it needs a request to your own server, and polling is a timer); a recipe in [`skills/fespalier-data/references/reconnect-and-network.md`](../skills/fespalier-data/references/reconnect-and-network.md) asks your own API once per connectivity change and per resume, never on a timer, and turns that into a `RefetchSignal`.

**Two platform repairs.** The web sends no first state (only `online` and `offline` events), so the first state is asked with `check()`; an event that arrives before that answer wins. iOS drops connectivity events while the app is in the background, so `networkConnectivity` asks `check()` again on each resume, through `appResumeSignal`. Neither starts a timer.

**Testing.** `package:fespalier_connectivity/testing.dart` has `FakeConnectivity`, a `ConnectivitySource` whose `set`, `offline()` and `online([via])` deliver a change **synchronously**, whose `check()` answers `now`, and which sends nothing on listen (like the web). Override `connectivitySource` with it (and `reconnectSignal` with `ConnectivitySignal.new`, as `startup()` does; `pumpRouter` does not run `startup()`):

```dart
final fake = FakeConnectivity();
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/teams/acme/members/7'),
  overrides: [
    connectivitySource.overrideWithValue(fake),
    reconnectSignal.overrideWith(ConnectivitySignal.new),
  ],
);
await tester.pump(const Duration(seconds: 31)); // the team is stale now (the fake clock)
fake.offline();
fake.online(); // a reconnect: the team loads again, once
await tester.pumpAndSettle();
```

A widget test that reaches the plugin without that override **fails**, with Flutter's report `while activating platform stream on channel dev.fluttercommunity.plus/connectivity_status` and `MissingPluginException(No implementation found for method listen on channel dev.fluttercommunity.plus/connectivity_status)` (a test that shows `hasNetwork`, or builds a `refetchOnReconnect` provider with the package's signal, and no `FakeConnectivity`).

In debug (`debugPrint`, nothing in a release build) it prints `fespalier_connectivity: the connectivity stream reported an error: <error>` and `fespalier_connectivity: checking connectivity failed: <error>`, and both leave the state as it was ([causes](../skills/fespalier-troubleshooting/references/diagnostics-flags-storage-network.md)).

### A cache that survives a restart: `dataCache`

Since 0.8.1 a `data.dart` can save its last value, and show it at the next start while the fresh one loads. It is built on Riverpod 3's **experimental** offline persistence (`persist()` and its `Storage` interface), isolated in one runtime file, and it is opt in twice: the `data.dart` declares how its value is saved, and the app gives a place to save it.

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:shop/api.dart';

final dataCache = DataCache<Product>.json(
  toJson: (p) => p.toJson(),
  fromJson: (j) => Product.fromJson(j! as Map<String, Object?>),
);

Future<Product> data(Ref ref, {required int id}) =>
    ref.watch(apiProvider).product(id);
```

`dataCache` is a top-level `const` or `final` variable of exactly that name, initialized with `DataCache(...)`, `DataCache<T>(...)`, `DataCache.json(...)` or `DataCache<T>.json(...)`. `.json` saves `jsonEncode(toJson(value))` and reads back `fromJson(jsonDecode(saved))`; the plain constructor takes `encode` and `decode` between your value and a `String`. `maxAge` (default two days) is how long a saved value may be shown at a start; `version` is a string you change when what `encode` writes changes shape (values saved under another version are dropped, not decoded). Like `freshness` it applies to the function form that loads once, and a `route.dart` can't have one (each data type has its own encode and decode).

**Where it is saved.** `dataCacheStorage` is a provider that is `null` by default, so **nothing is saved** until the app gives one in its `ProviderScope`:

```dart
ProviderScope(
  overrides: [dataCacheStorage.overrideWithValue(MemoryDataStorage())],
  child: const ShopApp(),
)
```

- `MemoryDataStorage` keeps values while the app runs: a page that is disposed and opened again shows its last value at once. For the web, examples and tests; it does not survive a restart.
- A `Storage<String, String>` on disk survives one. `fespalier_storage` (since 0.9.0, [below](#a-cache-on-disk-fespalier_storage)) is a tested one on shared_preferences or Hive, with a size budget; `riverpod_sqflite`'s `JsonSqFliteStorage` plugs in as it is. To write your own, import `package:fespalier/persist.dart` (it re-exports `Storage`, `PersistedData`, `StorageOptions` and `StorageCacheTime`); `read` returns a `PersistedData<String>?`.

For an app that keeps working without a network (reads that say how current they are, writes that wait, rows synced later), see [Offline-first](offline-first.md) and [CrateStack with fespalier](cratestack.md).

A storage whose `read` is synchronous gives the saved value on the first frame. A `Future<Storage>` is fine too: there is one `loading.dart` frame, then the saved value.

**What happens.**

1. The first time a route's provider is built (and each time after it was disposed), a saved value that has not expired and has the same `version` is the state: `AsyncLoading(value: saved)` with `isFromCache == true`, and the fetch starts at the same time. `DataView` shows such a value whatever `keep_previous` says. Read `isFromCache` from `XRoute.watch(ref)` for an "offline copy" banner.
2. The fetch succeeds: the state is the fresh `AsyncData`, and it is saved.
3. The fetch fails: the page keeps the saved value (`keepDataOnError`), **and the saved value is kept**. Riverpod's `persist` deletes it on any error, so an offline start would lose the cache for the next one; fespalier guards that. An offline cold start shows the last data, and so does the next one, until `maxAge`.
4. A saved value that does not decode is dropped, not reported as an error, and the load goes on. A storage that throws never becomes the route's error either.
5. A cold start always loads again, whatever the `staleTime` is. Nothing the storage answers after the load has finished replaces the fresh value.

In debug (`debugPrint`, nothing in a release build) it prints `fespalier: dataCache of <name> could not read a saved value, dropped it: <error>` and `fespalier: dataCache of <name> could not save: <error>`.

The key a value is saved under is `fespalier:<folder>` plus the route's keys in path order as JSON, e.g. `fespalier:products/$id[42]` (the folder is the `data.dart`'s, relative to the app folder, so it is stable across `fsp gen`). An enum key is saved by its `name`, a `DateTime` as ISO 8601, a list as a list, anything else by its `toString()`, which is how a custom segment type is spelled in a URL: keep that stable (a web release build that minifies class names would change it).

Don't write an optimistic value with `state =` on this provider's notifier: Riverpod saves every `AsyncData` it sets, so the guess would be saved. Keep optimistic values in a layer above the data provider.

**Testing.** With no `dataCacheStorage` override, nothing is saved. To test the cache, share a `MemoryDataStorage` between two `pumpRouter` calls, which stands in for a restart:

```dart
final storage = MemoryDataStorage();
await pumpRouter(tester, AppRoutes.router(initialLocation: '/products/1'),
    overrides: [dataCacheStorage.overrideWithValue(storage)]);
await tester.pumpWidget(const SizedBox());
await pumpRouter(tester, AppRoutes.router(initialLocation: '/products/1'),
    overrides: [dataCacheStorage.overrideWithValue(storage), apiProvider.overrideWithValue(OfflineApi())]);
expect(find.text('Coffee beans, 500 g'), findsOneWidget); // the saved product, not error.dart
```

`MemoryDataStorage` is synchronous, so a test leaves no pending future, and `await tester.pump(const Duration(days: 3))` expires a value under the fake clock.

### A cache on disk: fespalier_storage

Since 0.9.0. `package:fespalier_storage` is a tested `Storage<String, String>` for the [`dataCache`](#a-cache-that-survives-a-restart-datacache) above, on **shared_preferences** (`PrefsDataStorage`) or **Hive** (`HiveDataStorage`), with a size budget. A route's value is saved when it loads, and at the next start it is **on the first frame** while the fresh one loads. Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_storage:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_storage
      ref: v0.15.0
```

<!-- x-release-please-end -->

Open a storage in `startup()` and give it to `dataCacheStorage`:

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
];
```

`open()` is awaited there, so the first frame is the app: `startup()` costs one frame behind `splash.dart` (or the native splash), and `read()` is then a synchronous lookup, so Riverpod's `persist` gives the saved value to the first `build`. A `startup()` that prefers no extra frame can pass the `Future` itself (`dataCacheStorage.overrideWithValue(PrefsDataStorage.open())`): one `loading.dart` frame, then the saved value. `open()` returns `null` (and prints a debug line) when the store cannot open, and `dataCacheStorage` takes `null` as "save nothing": a cache never stops an app from starting.

| What           | `PrefsDataStorage`                                                           | `HiveDataStorage`                                                                    |
| -------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Backend        | `SharedPreferencesWithCache`; localStorage on the web                        | a `hive_ce` `Box<String>`; IndexedDB on the web                                      |
| Reads          | synchronous                                                                  | synchronous once the box is open                                                     |
| Default budget | 1,000,000 characters, 200 entries                                            | 4,000,000 characters, 1,000 entries                                                  |
| Plugins        | `shared_preferences` (most apps have it)                                     | none: `hive_ce` is pure Dart; `path_provider` for the cache directory                |
| Where on disk  | the platform's preferences, beside the app's own keys                        | `getApplicationCacheDirectory()` (OS-purgeable, not backed up), none on the web      |
| Pick it when   | a few small values; on the web localStorage is about 5 MB per origin, shared | more or larger values; opening reads the whole box, so `maxSize` also bounds startup |

**The budget.** `maxSize` is in `String.length` units (UTF-16 code units, what browsers count localStorage in), keys and headers included; `maxEntries` is a count. Over either, the entries **written longest ago** go first, ties by key (no timer, no background sweep). A route's value is written each time it is fetched fresh; reads never write. A value too large for `maxSize` is not saved: it fails with `DataEntryTooLarge`, which fespalier prints after `could not save`, and the route works. Expired and unreadable entries are deleted once, when the storage is made. A full web `localStorage` is a `QuotaExceededError` on the write: the entry is dropped and fespalier prints "could not save"; keep `maxSize` well below, or use Hive.

**Versioning, corrupt entries, sign-out.**

- `DataCache(version: '2')` is Riverpod's `destroyKey`: stored in the entry's header and compared on read, so another version is deleted, not decoded. The storage's own format is versioned by the entry's first line, `fsc1`; a later format is read as unreadable, which for a cache means "dropped and loaded again". To drop everything on an app update, call `clear()`; there is no storage-wide version key.
- **An unreadable entry** (not written by this storage, a truncated one, a value of another type under its key) is dropped at start and counted, and at a read it is a `FormatException` that fespalier prints (`dropped it`) and deletes. Hive also truncates a corrupt frame when it opens a box.
- **`clear()` is what a sign-out does**: the next start shows nothing from the previous user. It deletes every entry this storage saved, and nothing else. Values in memory are the app's to invalidate (watch [`authUserId`](auth.md#the-session) in a `data.dart` that belongs to the user).
- **One writer per store.** A background isolate that writes the same store makes the in-memory index stale until the next start.

In debug (`debugPrint`, nothing in a release build), next to fespalier's two lines above:

- `fespalier_storage: dropped <n> saved entries that could not be read`, at start
- `fespalier_storage: could not open shared preferences, so nothing is saved: <error>` and `fespalier_storage: could not open the Hive box <name>, so nothing is saved: <error>`, when `open()` returns `null`
- a value over the budget, after fespalier's `could not save:`: `fespalier_storage: the value saved under <key> is <size> characters, more than maxSize (<maxSize>), so it was not saved`

A budget of 0 or less throws an `ArgumentError` (`Invalid argument (maxSize): must be more than 0: 0`), and so does a `SharedPreferencesWithCache` with an allowList given to `PrefsDataStorage(prefs)`: the keys of a `dataCache` are not known in advance, so use `PrefsDataStorage.open()` ([messages](../skills/fespalier-troubleshooting/references/diagnostics-flags-storage-network.md)).

**Testing.** `package:fespalier_storage/testing.dart` has `fakePrefsStore([values])`, which makes shared_preferences an in-memory store for the test, and `memoryBox()`, a Hive box in memory for `HiveDataStorage(await memoryBox())`. Two `open()`s in one test share the store: that is a restart.

```dart
setUp(fakePrefsStore); // also before a test that boots AppMain.run() or AppMain.root(): startup() opens a storage

testWidgets('the saved team is on the first frame of the next start', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/teams/acme/members'),
    overrides: [dataCacheStorage.overrideWithValue(await PrefsDataStorage.open())],
  );
  await tester.pumpWidget(const SizedBox()); // the restart
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/teams/acme/members'),
    overrides: [dataCacheStorage.overrideWithValue(await PrefsDataStorage.open())],
    settle: false, // one frame, no more
  );
  expect(find.text('Team ACME'), findsOneWidget); // the saved team, not loading.dart
});
```

Without `fakePrefsStore()`, `open()` finds no platform and returns `null` (a debug line says `Bad state: The SharedPreferencesAsyncPlatform instance must be set.`): the cache is silently off.

**Not built.** A storage-wide version key; a byte-exact size (units are `String.length`); multi-isolate safety; encryption (open your own Hive box with a cipher and pass it to `HiveDataStorage(box)`).

### A Rust core's changes: fespalier_frb

Since 0.13.0. A Rust core behind [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) (or any other core) usually does two things: it answers calls (`core.order(42)`) and it **says what changed** on a `Stream` (`OrderChanged(42)`, `CartCleared`). The answers are a `data.dart`'s business; the stream is what keeps them current, and `package:fespalier_frb` is the part that wires the two without a listener of your own. It is a `Stream<E>` and Riverpod, so it has **no `flutter_rust_bridge` dependency**: the generated bindings pin their own runtime exactly (FRB 2.13 needs Dart 3.9.2, above the Flutter 3.32 floor), and a second pin could only conflict. Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_frb:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_frb
      ref: v0.15.0
```

<!-- x-release-please-end -->

**The feed and its topics.** A `ChangeFeed` is your core's stream as a provider; a topic says which events concern a key; a `data.dart` **watches** the topic, and the watch is the invalidation:

```dart
// lib/core/changes.dart
final changes = ChangeFeed<CoreEvent>((ref) => ref.watch(coreProvider).changes(), name: 'core');

/// Rebuilds what watches it when order [id] changes, and on no other event.
final orderChanged = changes.topic<int>((event, id) => event is OrderChanged && event.id == id);

// lib/app/orders/$id/data.dart
Future<Order> data(Ref ref, {required int id}) {
  ref.watch(orderChanged(id));
  return ref.read(coreProvider).order(id);
}
```

`changes.latest` is the **one subscription**: a provider that is never auto-disposed, so it is opened by the first topic anyone watches (the function you gave it runs once per container, because a generated stream accepts one listener) and cancelled by the container's disposal. Ten thousand topics are still one subscription. A topic's value is a counter per key that moves **only** when a matching event arrives after the first watch, so `data()` is rebuilt exactly then and the screen shows the usual reload (the old value stays up, `keepDataOnError` keeps the page if the reload fails, and the rest of [freshness](#freshness-staletime-resume-and-reconnect) applies). `changes.any` is the topic of every event (it counts them, each event of a burst included), for a provider that depends on the whole core (a badge count).

What it does not do. It starts no timer, schedules nothing and has no `listen` of its own: `test/no_timers_test.dart` allows none in `lib/`. Riverpod rebuilds lazily, so events that arrive before a dependent rebuilds (a burst in one frame, or a page that was paused) can share one rebuild, but **none is lost**: the feed remembers the last 64 events of its subscription (`changeLogCapacity`) and a topic looks at every one it missed, so a `[7, 42, 7]` burst still rebuilds the watcher of order 42, and `changes.any` counts each event of a burst. A watcher that missed more than 64, or whose core was restarted, rebuilds anyway (a rebuild too many is safe, one too few is not). Two equal events one after the other are still two changes (`Change.seq` numbers them, because Riverpod drops a state equal to the last). A stream error stays in `changes.latest` as an `AsyncError` and rebuilds no topic. Every watched key evaluates its matcher once per event: fine for tens or hundreds of watchers, so give a core that emits thousands of events a second coarser events (one per table) or use the table below. A page that is hidden in a tab has its watchers paused by Riverpod; they catch up when it comes back _(not checked on a device)_. If `open` does `ref.watch(coreProvider)` and the core is restarted, the stream is opened again and the next event counts as a change.

**A table, when you own the subscription.** If the app already has code that receives the events (or does not want to edit its `data.dart` files), an `InvalidationTable` is the pure form: rules from an event to the providers it makes stale, applied by a function you pass. It holds no container and no stream:

```dart
// lib/core/changes.dart
final table = InvalidationTable<CoreEvent>([
  InvalidationRule.on<OrderChanged, CoreEvent>((e) => [orderProvider(e.id), ordersProvider]),
  InvalidationRule.on<CartCleared, CoreEvent>((_) => [cartProvider]),
]);

// lib/app/startup.dart, in ready(container): the app's own subscription, held in a provider of the container
container.listen(changes.latest, (_, next) {
  final change = next.value;
  if (change != null) table.apply(change.event, container.invalidate);
});
```

`apply` invalidates each provider once and returns how many it invalidated. The `container.listen` in the app's `ready()` is the app's listener, not the package's; it dies with the container.

**Starting the core is the app's.** `RustLib.init` belongs to the generated bindings, which a generic package cannot name, so there is no adapter: call it from `startup()` through `initRustCore`, which reports one span, `fespalier.frb.init`, ending `ok` or `error` (the attribute `fespalier.frb.result`; not the error, its text or its stack trace) and rethrows the failure unchanged:

```dart
// lib/app/startup.dart
Future<void> startup() => initRustCore(RustLib.init);
```

`startup()` runs before the router exists, behind `splash.dart`; a failure there is reported and shown with `retry`, which runs `startup()` again. Use `ready(container)` ([App startup](app-startup.md)) **instead of or after** it when the core must be read on the app's own container before the first route: `startup()` has no container and can only return overrides, so a core that is a provider (a database to open from the app's directory, a session to restore) is awaited in `ready()`, after `RustLib.init` has run in `startup()`. The split also decides what a retry repeats: `startup()` retried runs `init` again, `ready()` retried does not. FRB's `init` throws `StateError('Should not initialize flutter_rust_bridge twice')` the second time (check the message in your version), so if `startup()` does other fallible work, do it **before** `initRustCore`, and keep everything that comes after the init (opening the store) in `ready()`. If it cannot be ordered so, guard the retry: `if (!RustLib.instance.initialized) await initRustCore(RustLib.init);`. The caveat: `initialized` can already be true when the failure came from the Rust initializer that `init` runs last, and the guard then skips a core that never started.

**Testing.** `package:fespalier_frb/testing.dart` has `FakeChangeSource`, a stream you feed (`emit`, `emitError`, `close`) whose `listenCount` proves the single subscription; override the core provider, or build the feed over `fake.stream`:

```dart
final fake = FakeChangeSource<CoreEvent>(broadcast: false); // a generated stream is single-subscription
final feed = ChangeFeed<CoreEvent>((ref) => fake.stream);
// ... pump the page that watches feed.topic(...)(42)
fake.emit(const OrderChanged(42));
await tester.pump(); // the page reloads
expect(fake.listenCount, 1);
```

A widget test never runs `startup()` (`pumpRouter` does not), so it needs no `RustLib.init` and no native library: the fake core is a provider override.

### Providers per page instance: fespalier_riverpod

Since 0.13.0. A `data.dart` is keyed by a **location**: `/c/1` is one provider however many times it is on screen. State that belongs to **one page on a navigator** (a draft being typed, a selection, a filter sheet's choice, a form step) is not that: `/c/1` pushed twice is two pages and should be two states, while `/c/1?q=2` after `/c/1`, or a [remount](navigation.md#remounting-a-page-remount) of the page, is the same page and keeps its state. `package:fespalier_riverpod` keys a provider by the page instance, using the identity core already computes for the route lifecycle (`pageInstanceId`, the same string as `RouteScope.id`). It adds no key, command or file kind, starts no timer and listens to nothing. Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_riverpod:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_riverpod
      ref: v0.15.0
```

<!-- x-release-please-end -->

**The key and the providers.** A `PageInstance<R>` is the instance's id plus its typed route, equal **by id** (the route is not part of equality). `pageProvider` and `pageNotifierProvider` are auto-dispose families keyed by it (Riverpod 3 has no separate auto-dispose family type: the results are a `ProviderFamily` and a `NotifierProviderFamily`):

```dart
// lib/core/chat_draft.dart
class ChatDraft extends Notifier<String> {
  ChatDraft(this.page);
  final PageInstance<ChatRoute> page;

  @override
  String build() => '';

  void set(String text) => state = text;
}

final chatDraft = pageNotifierProvider<ChatDraft, String, ChatRoute>(ChatDraft.new);

// lib/app/chats/$id/page.dart
class ChatPage extends ConsumerWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = PageInstance.of(context, ChatRoute.of); // or usePageInstance(ChatRoute.of) in a hook widget
    final draft = ref.watch(chatDraft(page)); // watched, so the state is kept while the page is shown
    return Scaffold(
      body: Column(
        children: [
          TextField(onChanged: (text) => ref.read(chatDraft(page).notifier).set(text)),
          Text('draft: $draft'),
        ],
      ),
    );
  }
}
```

`PageInstance.of(context, ChatRoute.of)` reads the page's `GoRouterState` and the generated `XRoute.of`; call it in the page or below it. `usePageInstance(ChatRoute.of)` (a `flutter_hooks` hook, which fespalier already exports) is the same instance made once per page instance, so a query change gives the same object. The provider keeps the route the key was **first** made with: what depends on the query belongs to the page's `data.dart`, which is keyed by the whole location. The state lives as long as something watches it (a `read` alone does not keep an auto-dispose provider, so the page **watches**), and is disposed after the page's last widget goes (a pop, a `go` to another instance).

**Keeping it while no widget watches.** Riverpod 3 counts a paused subscription, so a parked tab or a covered page that **watches** its state keeps it without any hold. The hold is for state the page reads but does not watch, or that must outlive its widgets' watches. From an `observe.dart`, `holdForPage` ties it to the page's `RouteScope` (`scope.hold` under a name that says why); `onEnter` fires when a page first becomes the top page, so a page under a deep-linked stack is held only once it is on top. It lives from `onEnter` until the page leaves, and the page and the hook share it because `PageInstance.ofScope(scope, route)` and `PageInstance.of` give equal keys for one instance:

```dart
// lib/app/chats/$id/observe.dart
void onEnter(Ref ref, {required int id, required RouteScope scope}) {
  holdForPage(scope, chatDraft(PageInstance.ofScope(scope, ChatRoute(id: id))));
}
```

**Testing.** `package:fespalier_riverpod/testing.dart` has `TestPageInstance(route, id:)`, a key for a test without a router (the default `id` is `'test'`; the same `id` is the same key). With a router, the instance is what the page builds, so `pumpRouter` and `go`/`push` are the test; in a widget test call `await tester.runAsync(container.pump)` after a navigation before you count disposals, because Riverpod disposes an unlistened provider in a task of its own.

```dart
final one = TestPageInstance(const ChatRoute(id: 1), id: 'first push');
final two = TestPageInstance(const ChatRoute(id: 1), id: 'second push');
expect(container.read(chatDraft(one)), isNot(same(container.read(chatDraft(two)))));
```

What it does not do. It keeps nothing across a restart (a draft that must survive is [`dataCache`](#a-cache-that-survives-a-restart-datacache) or the form drafts of [Forms](forms.md)), and a state is per container, so a second `ProviderScope` has its own.

## Typed helpers on the route

A route with a `data.dart` has three more helpers next to `.data` and `.refresh` (and every route below a [section](#section-data) with data has `preload`, below):

```dart
final product = ProductRoute.watch(ref, id: 42);   // AsyncValue<Product>, for build()
final p = await ProductRoute.read(ref, id: 42);    // Future<Product>, for callbacks
final warm = ProductRoute(id: 42).prefetch(ref);   // a PrefetchHandle, before navigating
final all = ProductRoute(id: 42).preload(ref);     // the same, for everything the page reads
```

`watch` includes the patches of an [`optimistic()`](actions.md#optimistic-updates-optimistic) when the data has any (since 0.8.1).

**`watch` and `read` are static**, and take the keys the provider uses as named arguments (`ItemRoute.watch(ref, shop: 'a', id: 1)`, `SearchRoute.watch(ref, q: 'ap', page: 2)`; none for a route without keys). They can't be instance methods: [why](faq.md#why-watch-and-read-are-static).

**`read`** keeps the provider alive until it completes, which a plain `ref.read(p.future)` doesn't for an `autoDispose` provider. Don't call it from `build`. On a route with a [`freshness`](#freshness-staletime-resume-and-reconnect) (since 0.8.1) it returns the value in memory even if it is stale, and starts the reload; `refresh` waits for the network.

**`prefetch(ref)`** starts the load and returns a `PrefetchHandle` that **keeps the provider alive until you call `close()`** on it, so the page you navigate to next shows the value at once. The generated providers are `autoDispose`, so a prefetch nobody watches would be dropped in the same frame; the handle holds it, and how long is yours to decide. Call it before `go`, e.g. on hover:

```dart
MouseRegion(
  onEnter: (_) => _warm = ProductRoute(id: p.id).prefetch(ref),
  onExit: (_) => _warm?.close(),
  child: ListTile(onTap: () => ProductRoute(id: p.id).go(context), …),
)
```

- `keepFor:` is an optional auto-close: `prefetch(ref, keepFor: Duration(seconds: 30))` closes the handle after that long. While the widget is alive `keepFor` holds a timer, so a widget test that uses it should `pump` past it (or pass `Duration.zero`, which starts the load and keeps nothing).
- A failed load isn't kept (the handle closes itself): the page starts a fresh one instead.
- Closing twice is fine, and `handle.isClosed` tells.
- The subscription also ends when the widget whose `ref` you pass is disposed, which closes the handle and cancels its `keepFor` timer with it (since 0.5.0), so no timer outlives the widget. A `prefetch(ref)` whose handle is dropped lasts as long as the widget behind `ref`.

**`preload(ref)`** (since 0.5.0) warms _everything the page reads_, where `prefetch` warms the route's _own_ `data.dart`: the data of each [section](#section-data) above it, then its own, the list `AppRoutes.dataAt` gives for its location, behind one handle that closes them all (see [Links](navigation.md#links-routelink)). A route with no data at all returns a closed handle; one whose page is [deferred](navigation.md#deferred-routes-a-pages-code-on-demand) (since 0.7.0) also starts loading its code.

**Reserved names.** Because these are members of the route class, `watch`, `read`, `prefetch`, `preload`, `refresh`, `ref` and `keepFor` can't be segment or query names, nor (since 0.5.0) can `of`, `maybeOf` and `copyWith` (see [the URL as state](navigation.md#the-url-as-state-of-and-copywith)), nor the helpers of an [`action.dart`](actions.md#actiondart-typed-writes) (`submit`, `useAction`, or an action's own name).

## From a location to its data

An app's own prefetch layer often starts from a _location_ (the next page a list points at), not from a route it built by hand. Two generated functions on `AppRoutes` answer that from the tree, without a table of your own:

```dart
final providers = AppRoutes.dataAt(Uri.parse('/products/42'));
// [ProductRoute.data(42)]: the provider the page watches, so warming it warms the page.
final handle = ref.prefetchAll(providers ?? const []);   // one PrefetchHandle for them all
// ... later, when your queue's lease ends:
handle.close();
```

`dataAt(uri)` is a `List<ProviderListenable<AsyncValue<Object?>>>?`, **outermost first**: the `data.dart` of each [section](#section-data) above the route, then its own. It is:

- `null` when no route fits the location, or when a segment doesn't parse (`/products/abc` where the id is an `int`): the rule that shows `not_found.dart`;
- empty for a route without data (a page, or a catch-all with nothing behind it): a match, with nothing to warm.

The key is built by the parser the route uses, so `dataAt(Uri.parse('/products/42')).single == ProductRoute.data(42)`; for a `data.dart` that [selects a provider](#datadart-a-function-a-selector-or-a-provider) it is the selected provider itself (your own `productProvider('42')`). Query-keyed data is keyed by the location's query (`/search?q=ap&page=2` is `SearchRoute.data((q: 'ap', page: 2, …))`, lists as the `QueryList` the page's key uses), a [catch-all](routing.md#catch-all-segments) by its decoded path. The mount point (`AppRoutes.mount(at: '/shop')`) is taken off first and a location outside it is `null`; each route matches by its own case setting, and a [typed catch-all](routing.md#typed-catch-alls) part that does not parse is no match. Nothing else runs: no `guard.dart`, no `redirect.dart`, no widget (prefetching what the user asked for is your queue's call, even if a guard sends them elsewhere).

`AppRoutes.preload(ref, uri)` (since 0.5.0) is `ref.prefetchAll(dataAt(uri) ?? const [])`: one handle for everything the page at `uri` reads, a closed one when nothing fits or there is nothing to warm. It never navigates and runs no guard. In an app with a [deferred route](navigation.md#deferred-routes-a-pages-code-on-demand) (since 0.7.0) it is `matchUrl(uri)?.route.preload(ref)` instead, which also starts the page's code.

`AppRoutes.match(uri)` is what `dataAt` is a shortcut for (`match(uri)?.data`). It returns a `RouteMatch`, or `null` under the same rules:

```dart
final m = AppRoutes.match(Uri.parse('/shops/acme/items/7'))!;
m.info;      // the RouteInfo from the manifest: path '/shops/:shop/items/:id', folder, meta, ...
m.params;    // {'shop': 'acme', 'id': 7}: the segments and query parameters, parsed
m.route;     // ItemRoute(shop: 'acme', id: 7), typed; m.route.location is its canonical spelling
m.data;      // the providers, as dataAt returns them
m.uri;       // the location it was given
```

Routes are tried most specific first (static parts, then `:param`s, then catch-alls), the order go_router uses. `match` lives on the manifest (`AppManifest.match`, forwarded by `AppRoutes`), so with [`output_manifest:`](routing.md#route-manifest-and-metadart) it is in the manifest library; `AppRoutes.dataAt` and `AppRoutes.matchUrl` (a `UrlMatch`: the route, params and data without the `RouteInfo`) stay in `app.g.dart`, which never imports a `meta.dart`. `RouteMatch` is fespalier's: `package:fespalier/fespalier.dart` hides go_router's own, so import `package:go_router/go_router.dart` for that one.

## Section data

A folder with a `layout.dart` and no `page.dart` (a `(group)`, or a plain folder that only holds routes) can have a `data.dart` too. It is then the data of the whole section: the layout waits for it, and the layout and the pages below can take it.

```dart
// lib/app/teams/$teamId/data.dart
Future<Team> data(Ref ref, {required String teamId}) => …;

// lib/app/teams/$teamId/layout.dart: by type (or a parameter named `data`)
class TeamLayout extends StatelessWidget {
  const TeamLayout({super.key, required this.team, required this.child});
  final Team team;
  final Widget child;
  …
}

// lib/app/teams/$teamId/members/page.dart: the page takes it by type as well
class MembersPage extends StatelessWidget {
  const MembersPage(this.team, {super.key});
  final Team team;
  …
}
```

- **Loading and errors.** While the section loads, the nearest `loading.dart` (inherited as usual) replaces the layout _and_ the pages inside it, and a failure shows the nearest `error.dart` with its `retry`. Nothing below is built until the data is there.
- **Sharing.** The layout watches the provider and the pages below read the same one, so `data()` runs once however many of them take it, and moving between the section's pages doesn't load it again. When the data reloads (`retry`, an invalidation), the section keeps showing what it has (`keep_previous`; with `keep_previous: false` it shows loading again).
  **Which one.** A parameter called `data` gets the nearest data: the route's own `data.dart`, then the section's, then the next section up. By type, a parameter gets the `data.dart` that yields that type; it is an error if two do (a page's own and a section's, or two sections'), so name the parameter `data` for the nearest or give one of them another type. A page can have its own `data.dart` and take a section's by type.
  **Keys.** A section's `data()` takes segments (at or above its folder) and, like a page's, query parameters: `Future<Report> data(Ref ref, {String? period})` keys the section by `?period=` of the location, which the layout reads from the URL like any layout query parameter. Every route below the section is keyed by it too: `period` becomes a query parameter of each of their typed routes (`MonthlyReportRoute(period: '2026-01')` writes `/reports/monthly?period=2026-01`), so the pages read the same provider the layout loaded. A page that declares the same name with another type is an error.
- **Typed handle.** A section has no route of its own, so it gets a class named after its folder, with `Section` on the end (`teams/$teamId` is `TeamsTeamIdSection`, `(shop)` is `ShopSection`, the app folder `RootSection`; two folders that name the same class are an error). Its members are static and take the section's keys as named arguments, like a route's:

  ```dart
  TeamsTeamIdSection.data('acme');                         // the provider
  TeamsTeamIdSection.watch(ref, teamId: 'acme');           // AsyncValue<Team>
  await TeamsTeamIdSection.read(ref, teamId: 'acme');      // Future<Team>
  final h = TeamsTeamIdSection.prefetch(ref, teamId: 'acme');   // PrefetchHandle
  await TeamsTeamIdSection.refresh(ref, teamId: 'acme');
  ```

  A key can't be called `ref`, `keepFor` or another of the handle's members.

- **Where it applies.** A layout of any kind can be a section's, tab layouts included. A `data.dart` beside a `page.dart` keeps feeding that page, so the folder that holds the section's layout mustn't have a page.
