---
name: fespalier-data
description: "How fespalier routes load data — data.dart and its three forms (a function, a selector of a provider you already have, or a provider you write), how segments and query parameters key the provider, loading.dart and error.dart, keep_previous and data_retry, section data and the typed Section handle, prefetch handles, the typed watch/read/refresh helpers, AppRoutes.dataAt and match, and how it all sits on Riverpod 3. Load before writing or changing a data.dart, a loading or error view, a retry policy, or an app-level prefetch queue, or when a page flashes loading.dart or shows a stale value."
---

# fespalier-data

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/vaam-apps/fespalier/blob/main/skills/README.md#versions).

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

## Typed helpers, prefetch, lookup

```dart
ProductRoute.watch(ref, id: 42);             // static: AsyncValue<Product>, in build()
await ProductRoute.read(ref, id: 42);        // static: Future<Product>, in callbacks
final warm = ProductRoute(id: 42).prefetch(ref);   // PrefetchHandle: kept until close()
await ProductRoute(id: 42).refresh(ref);
AppRoutes.dataAt(Uri.parse('/products/42')); // [ProductRoute.data(42)]; null if no route fits
AppRoutes.match(Uri.parse('/products/42'));  // RouteMatch: info, parsed params, typed route, data
```

- **`prefetch` holds until you `close()` the handle** (0.3.0 changed this from a
  30 s lapse; `prefetchKeepAlive` is gone). `keepFor:` auto-closes; `Duration.zero`
  keeps nothing; a failed load closes its own handle.
- **`dataAt` is outermost first** (sections, then the route) and is `null` for an
  unknown location **or an unparsable segment**; no guard runs and no widget is
  built.
- `watch`/`read` are static because an instance member would have to name your
  data type in the generated file. Do not call `read` from `build`.

[`references/prefetch-and-lookup.md`](references/prefetch-and-lookup.md) covers
these, `prefetchAll`, `RouteMatch` (fespalier hides go_router's own
`RouteMatch`) and Riverpod overrides.

## Common symptoms

| Symptom                                            | Look at                                                                                    |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Page blinks to `loading.dart` on every reload      | `keep_previous: false` in `pubspec.yaml` (the default is `true`)                           |
| A failing `data.dart` runs several times in a test | Default `data_retry: inherit`; `pumpRouter` already disables retries (`fespalier-testing`) |
| `error.dart` never shows during a retry            | A function-form `data()` wrapping `.future` of your provider: use a selector               |
| `refresh`/`retry` throws a `StateError`            | A selector that returns `.select(...)` of a provider: return the provider itself           |
| A prefetched page still loads                      | The handle was closed, or the id/query differs from the key the page uses                  |
| `dataAt` is `null` for a URL that works in the app | The segment fails to parse, or the URL is outside the mount prefix                         |
| An fsp error on `data.dart`                        | `fespalier-troubleshooting`                                                                |
