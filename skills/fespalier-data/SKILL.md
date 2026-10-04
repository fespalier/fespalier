---
name: fespalier-data
description: "How fespalier routes load data — data.dart and its three forms (a function, a selector of a provider you already have, or a provider you write), how segments and query parameters key the provider, loading.dart and error.dart, keep_previous and data_retry, section data and the typed Section handle, prefetch handles and preload (the whole page's data behind one handle, as RouteLink uses it), the typed watch/read/refresh helpers, AppRoutes.dataAt and match, and how it all sits on Riverpod 3 — freshness and the data cache (since 0.8.1: staleTime, refetch on resume and reconnect, dataCache, DataCache, MemoryDataStorage, keepDataOnError), and action.dart, the write side (typed submit and useAction, pending and error state, what a success invalidates, and since 0.8.1 its forms: form(), validate() and optimistic()), and since 0.9.0 how models, immutable collections, validation libraries and results meet it (freezed, dart_mappable, fast_immutable_collections, acanthis, result_dart). Load before writing or changing a data.dart or an action.dart, a loading or error view, a retry policy, or an app-level prefetch queue, or when a page flashes loading.dart, shows a stale value or does not refresh after a write."
---

# fespalier-data

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

`data.dart` is what a route loads. Beside a `page.dart` it feeds that page: the
page is **only built once the data has arrived**, `loading.dart` shows meanwhile
and `error.dart` if it fails. Everything is Riverpod 3 underneath
(`package:fespalier/fespalier.dart` re-exports `hooks_riverpod`).

## Pick a form

| You have                                        | Write                                                                                                   |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Nothing yet; the fetch belongs to this route    | `Future<Product> data(Ref ref, {required int id}) => fetchProduct(id);`                                 |
| A provider already (often riverpod_generator's) | `ProviderListenable<AsyncValue<Product>> data({required int id}) => productProvider(id);`               |
| A notifier, `keepAlive` or `retry:` of your own | `final data = AsyncNotifierProvider<MyNotifier, Product>(MyNotifier.new);` (type arguments spelled out) |

**Do not** wrap a provider you have in `ref.watch(p(id).future)` inside a
function-form `data()`: a second provider in front of the real one drops the
error the real provider holds while it retries, so `error.dart` cannot show during
the retry window. Use the selector. Details, errors and samples that compile:
[`references/data-forms.md`](references/data-forms.md).

## Keys

The route exposes its data as `XRoute.data`, **keyed by the segments and query
parameters `data.dart` uses**: no keys gives a plain provider, one key a
`.family<T, int>` (`ProductRoute.data(42)`), several a record
(`ItemRoute.data((shop: 'a', id: 1))`). A `List` query parameter is keyed by a
`QueryList` (value equality); a catch-all by its encoded path; an enum by the
enum. A provider **you** write can be keyed by segments only.

A parameter of `data()` that is neither a segment nor an optional nullable query
parameter is an error naming it; the types must agree with every other file that
asks for the same segment.

## Loading, errors and reloads

- `loading.dart` and `error.dart` are **inherited** by every folder below, nearest
  wins, and can ask for the route's segments and query parameters (`error.dart`
  also for `error`, `stackTrace`, `retry`). Without any: `DefaultLoading` and
  `DefaultError`.
- **`keep_previous: true` (default):** `loading.dart` is only for the **first**
  load; a reload keeps rendering the old value or error. `false`: loading shows on
  every load.
- **`data_retry: inherit` (default):** generated providers set **no retry of their
  own**, so Riverpod 3's automatic retry (10 attempts with backoff) or your
  `ProviderScope(retry:)` applies; during the retry window `error.dart` stays up.
  `none`: a failure is final until `error.dart`'s `retry` runs it again. A selector
  or a provider you write ignores `data_retry`.

`references/loading-error-retry.md` has the mechanics and the test behaviour.

## Sections

A folder with a `layout.dart` and **no** `page.dart` can have a `data.dart`: the
data of the whole section. The layout waits for it (nearest `loading.dart`
replaces layout **and** pages meanwhile), and the layout and pages below take it
**by type** or as a parameter called `data`. `data()` runs **once** however many
take it. A typed handle (`TeamsTeamIdSection.watch/read/prefetch/refresh/data`)
is generated for it. Two `data.dart` files yielding the same type for one
parameter are an error: name the parameter `data` (the nearest) or change a type.
See [`references/sections.md`](references/sections.md).

## Freshness and the cache (since 0.8.1)

Opt in, per `data.dart` or per folder; an app that declares neither generates what 0.7.0 did.

```dart
const freshness = Freshness(staleTime: Duration(minutes: 1), refetchOnResume: true); // data.dart or route.dart
final dataCache = DataCache<Product>.json(toJson: (p) => p.toJson(), fromJson: (j) => Product.fromJson(j! as Map<String, Object?>)); // data.dart only
```

| Rule                                                                     | What it means                                                                                                                                                                                  |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Where                                                                    | `freshness` in a `data.dart` (that data) or a `route.dart` (every function-form `data()` at and below; the nearest wins, a `data.dart`'s own wins over all). `dataCache` in a `data.dart` only |
| Which forms                                                              | The function form (`Future<T>`, `FutureOr<T>` or `T`). A `Stream`, a selector and a provider form are errors; a `route.dart` default skips them silently                                       |
| Stale                                                                    | In memory for `staleTime` **since it arrived**. Loading and error values are never stale. Nothing polls                                                                                        |
| What loads a stale value                                                 | A **read**: a new listener (a page opening, `SectionView`, `prefetch`/`preload`, `read`), a listener coming back (page uncovered, tab shown), or a resume/reconnect signal                     |
| What it shows meanwhile                                                  | The stale value **at once**, then the new one (`keep_previous` decides if `loading.dart` shows)                                                                                                |
| `refetchOnResume` / `refetchOnReconnect`                                 | Signals (`appResumeSignal`, `reconnectSignal`); threshold `staleTime ?? Duration.zero`. `reconnectSignal` **never fires by itself**: override it or call `fire()`                              |
| A failed reload                                                          | Keeps the page on its data (`keepDataOnError: true` on the `DataView`); `error.dart` only when there is nothing to show                                                                        |
| An invalidation (`ref.invalidate`, `refresh`, an action's `invalidates`) | Loads **at once**, whatever the `staleTime`: it is not a read                                                                                                                                  |
| `dataCache`                                                              | Saved only if the app overrides `dataCacheStorage` (`null` by default). `MemoryDataStorage` for tests and the web; a `Storage<String, String>` on disk to survive a restart                    |

Gotchas: every new reader counts (a small `staleTime` reloads a section each time a page below it opens);
`read` returns what is in memory even if stale (`refresh` waits for the network); `keepFor` is how long a
handle holds a value, not freshness; a failed user `refresh()` is hidden behind the old page; a cold start
always loads again; a failed load never deletes the saved value; `freshness` and `dataCache` are names `fsp`
now reads in a `data.dart` (a public variable of that name and another type is an error: rename it).
[`references/freshness-and-cache.md`](references/freshness-and-cache.md) has the samples that compile, the
reconnect signal, the storage, the key format and the tests.

## Typed helpers, prefetch, lookup

```dart
ProductRoute.watch(ref, id: 42);             // static: AsyncValue<Product>, in build()
await ProductRoute.read(ref, id: 42);        // static: Future<Product>, in callbacks
final warm = ProductRoute(id: 42).prefetch(ref);   // PrefetchHandle: kept until close()
final all = ProductRoute(id: 42).preload(ref);     // 0.5.0: the page's whole data, sections included
final byUri = AppRoutes.preload(ref, Uri.parse('/products/42'));   // 0.5.0: the same from a location
await ProductRoute(id: 42).refresh(ref);
AppRoutes.dataAt(Uri.parse('/products/42')); // [ProductRoute.data(42)]; null if no route fits
AppRoutes.match(Uri.parse('/products/42'));  // RouteMatch: info, parsed params, typed route, data
```

- **`prefetch` holds until you `close()` the handle** (0.3.0 changed this from a
  30 s lapse; `prefetchKeepAlive` is gone). `keepFor:` auto-closes; `Duration.zero`
  keeps nothing; a failed load closes its own handle.
- **`preload` (0.5.0) is `prefetch` for everything the page reads**: the data of each
  section above it, then its own, behind one handle, never navigating and never
  running a guard. `RouteLink(preload: ...)` calls it for you
  ([`fespalier-routing`](../fespalier-routing/), its links page); a link whose
  page still shows `loading.dart` after a hover usually has `Preload.none` (the
  default) or a `uri:` without `RouteLinkScope(match: AppRoutes.matchUrl)`.
- **`dataAt` is outermost first** (sections, then the route) and is `null` for an
  unknown location **or an unparsable segment**; no guard runs and no widget is
  built.
- `watch`/`read` are static because an instance member would have to name your
  data type in the generated file. Do not call `read` from `build`.

[`references/prefetch-and-lookup.md`](references/prefetch-and-lookup.md) covers
these, `prefetchAll`, `RouteMatch` (fespalier hides go_router's own
`RouteMatch`) and Riverpod overrides.

## Writes: `action.dart` (since 0.5.0)

`action.dart` is the write side of a route: `Future<Refund> action(Ref ref, {required
int id, required RefundInput input})`, beside the `page.dart` (or, in a page-less
folder, beside the `layout.dart` of a section). Segments and query parameters bind as in
`data.dart`; the one other parameter is a **named, required `input`**, of any type.

```dart
final refund = RefundRoute.useAction(ref, id: id);   // build(): state, isPending, hasError, call(input)
await RefundRoute.submit(ref, id: 1, input: input);  // a callback or a test: the result, or it throws
```

- **State is a generated Notifier family** (`RefundRoute.action(1)`): `AsyncValue<T?>`,
  `AsyncData(null)` when idle. It works without a widget, in a `ProviderContainer`.
- **A failed write shows in `state`, not `error.dart`, and is never retried.** The handle's
  `call` never throws; `submit` does.
- **After a success** the route's own `data.dart` and the sections' above it are
  invalidated, or what `const invalidates = [OrderRoute, ...]` lists (typed route and
  section names, not providers; it replaces the default set; `<Object>[]` for none). The
  action has to take the keys of what it invalidates.
- **Any number of actions per file**, each a public function with a `Ref` first; a
  function not called `action` names its helpers after itself (`approve`,
  `useApprove`). A sync action stays sync.
- **Navigation after success is the caller's**; check `context.mounted` after the `await`.

[`references/actions.md`](references/actions.md) has the rules, the generated members,
what is invalidated and a test that compiles.

## Forms and optimistic updates (since 0.8.1)

Not a file kind: `form()`, `validate()` and `optimistic()` are _companion functions_ in the
`action.dart` of their action (`approveForm`, `approveValidate`, `approveOptimistic` beside
`approve`), and never actions themselves.

```dart
typedef NicknameFields = ({String nickname, bool newsletter});   // the input: a record, named fields
NicknameFields form(Profile profile) => (nickname: profile.nickname, newsletter: profile.newsletter);
FieldErrors? validate(NicknameFields input) => FieldErrors({if (input.nickname.isEmpty) 'nickname': 'Enter a nickname'});
Profile optimistic(Profile current, NicknameFields input) => Profile(input.nickname, input.newsletter);
// page (a HookConsumerWidget): final form = NicknameRoute.useForm(ref, data: profile);
```

- **The input is a record with named fields**, inline or a `typedef` in the **same** `action.dart`.
  `useForm` gives `form.fields.nickname.controller` / `.value` / `.error`, `onSubmit` (**null while
  the action runs**), `isPending`, `isDirty`, `error`, `reset()`. It is a **real hook**: only in a
  `HookConsumerWidget`. `data:` is the data the page got.
- **`validate()` runs in the form and in the action's provider**, before the action: a refused
  input never starts the write. The action throws `FieldErrors({'field': 'message'})` for what
  only the server knows; keys are the record's field names.
- **`optimistic()` patches the `data.dart` the action invalidates whose type is `T`**: shown from
  the start of the write, removed on failure, kept over the old value after a success until the
  data has loaded again (no frame of the old value, `keep_previous: false` too). `XRoute.data`,
  `read` and `refresh` stay the server's value.
- Fields the user has not changed follow new data; changed ones keep what was typed.

[`references/forms-and-optimistic.md`](references/forms-and-optimistic.md) has every rule and a
sample that compiles, with its test.

## Models, collections, validation and results (since 0.9.0)

fespalier depends on **none** of freezed, dart_mappable, fast_immutable_collections, acanthis, luthor,
result_dart or fpdart, and `fsp` does not read them: they meet it in the value `data()` returns (Riverpod 3 filters
updates by `==`), an `extra` (freezed's factory syntax is a private `_Note`: `ExtraCodec.of`), `DataCache.json`
(dart_mappable's `toJson()` is a String: pass `toMap`), an action's record `input`, `validate()` and the failures
`data()` and `action()` throw.

- **Pick by Dart:** freezed 4.0.2 needs Dart 3.13 (Flutter 3.47), freezed 3.2.5 covers Dart 3.8 and up, dart_mappable
  4.10 needs 3.7; acanthis 2 needs Dart 3.13 (1.x, a different API, below it).
- **A selected `List` field notifies on every reload**, equal or not; an `IList` from fast_immutable_collections 12
  does not (measured, with a test that builds).
- **`validate()` stays a plain function**; a schema library is an adapter inside it. **Unwrap a result in `data()`**
  (`getOrThrow()`, or fpdart's `getOrElse((l) => throw l)`), so `error.dart` can switch on the sealed failure.
- A model class is not a form's `input` (a record is), and `build_runner` can delete `lib/app.g.dart`
  (`fespalier-troubleshooting`, its flutter-pitfalls page).

[`references/models-and-libraries.md`](references/models-and-libraries.md) has the samples that compile, the
primary-constructor note and what is not built.

## Seeing it in DevTools (since 0.7.0)

The `fespalier` tab's **Data** tab lists each provider fespalier makes from a `data.dart`: its state
(`loading`, `data`, `error`, `stream`, `disposed`), builds, listeners, key and value, with an **Invalidate**
button and, since 0.8.1, a **Holders** button that lists who keeps the provider (the page, a section, a
`prefetch` / `preload` handle, a `RouteLink` preload) and counts the other listeners. **Actions** lists the
runs of the `action.dart` functions. The generated provider body is wrapped in `traceData`, which returns the
function's own result (a value stays a value, a `Future` stays the `Future`), and every view watches with
`watchData(ref, 'd37', provider)`, which is `ref.watch`. A `data.dart` that returns or selects a provider is
followed since 0.8.1 as an `app provider`, through the state the views got; its other listeners are not
visible (`fespalier-troubleshooting`, its DevTools page).

## Common symptoms

| Symptom                                            | Look at                                                                                                                       |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Page blinks to `loading.dart` on every reload      | `keep_previous: false` in `pubspec.yaml` (the default is `true`)                                                              |
| A failing `data.dart` runs several times in a test | Default `data_retry: inherit`; `pumpRouter` already disables retries (`fespalier-testing`)                                    |
| `error.dart` never shows during a retry            | A function-form `data()` wrapping `.future` of your provider: use a selector                                                  |
| `refresh`/`retry` throws a `StateError`            | A selector that returns `.select(...)` of a provider: return the provider itself                                              |
| A prefetched page still loads                      | The handle was closed, or the id/query differs from the key the page uses                                                     |
| `dataAt` is `null` for a URL that works in the app | The segment fails to parse, or the URL is outside the mount prefix                                                            |
| A page doesn't refresh after a write               | The data is another route's: list it in `invalidates` (`references/actions.md`)                                               |
| A stale value stays on screen                      | Nothing read it: `freshness` loads on a read, a resume or a reconnect, never by a timer (`references/freshness-and-cache.md`) |
| Offline start shows `error.dart`                   | No `dataCache`/`dataCacheStorage`, or nothing was saved yet or it passed `maxAge`                                             |
| The form forgot what I typed (0.8.1)               | The data loaded again while the fields were untouched: only fields the user changed are kept                                  |
| The page flashes the old value after a save        | `optimistic()` patches another type than the page shows, or the data is not in `invalidates`                                  |
| An fsp error on `data.dart` or `action.dart`       | `fespalier-troubleshooting`                                                                                                   |
