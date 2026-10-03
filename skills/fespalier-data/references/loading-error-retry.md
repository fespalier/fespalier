# `loading.dart`, `error.dart`, retries and reloads

As of v0.4.0. Two settings in the `fespalier:` section of `pubspec.yaml` decide
what a route shows while its `data.dart` fails or loads again:
`keep_previous` (default `true`) and `data_retry` (default `inherit`). Both
changed behaviour in 0.3.0 against 0.1.1 (see `fespalier-migration`).

## The views

`loading.dart` and `error.dart` are **inherited by every folder below**, the
nearest one winning, and are bound **separately for each route they cover**:
they can ask for the segments and query parameters of that route, and
`error.dart` for `error`, `stackTrace` and `retry` as well. Without any,
fespalier uses `DefaultLoading` (a centred adaptive spinner) and `DefaultError`
(the error text and a Retry button).

```dart
// lib/app/loading.dart
import 'package:flutter/material.dart';

class RootLoading extends StatelessWidget {
  const RootLoading({super.key});

  @override
  Widget build(BuildContext context) => const Text('loading');
}
```

```dart
// lib/app/error.dart
import 'package:flutter/material.dart';

class RootError extends StatelessWidget {
  const RootError({super.key, required this.error, required this.retry});

  final Object error; // Object or dynamic: a narrower type is an error
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('failed: $error'),
      TextButton(onPressed: retry, child: const Text('Try again')),
    ],
  );
}
```

```dart
// lib/app/items/$id/error.dart
import 'package:flutter/material.dart';

// Closer than the root's, so it wins below items/$id/. It can ask for this
// route's segments as well.
class ItemError extends StatelessWidget {
  const ItemError({
    super.key,
    required this.id,
    required this.error,
    required this.retry,
  });

  final int id;
  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text("couldn't load item #$id: $error"),
      TextButton(onPressed: retry, child: const Text('Retry')),
    ],
  );
}
```

```dart
// lib/app/items/$id/data.dart
import 'package:fespalier/fespalier.dart';

Future<String> data(Ref ref, {required int id}) async =>
    throw StateError('offline');
```

```dart
// lib/app/items/$id/page.dart
import 'package:flutter/material.dart';

class ItemPage extends StatelessWidget {
  const ItemPage({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(label);
}
```

- A `loading.dart` or `error.dart` file below a **section** is built by the
  section's layout, which reads the URL for its segments and query
  parameters.
- `error.dart`'s `retry` **invalidates the provider** (for a selector, the
  selected provider, through `invalidateSelected`). The error stays up until the
  new run has an answer.
- **A deferred page's code load uses them too (since 0.7.0).** A route whose `page.dart` is
  [deferred](../../fespalier-routing/references/route-dart.md#deferred-load-a-pages-code-on-demand)
  shows the nearest `loading.dart` until its code has arrived, with or without a `data.dart`, and
  the nearest `error.dart` when loading the code fails: `error` is what `loadLibrary()` threw (a
  `DeferredLoadException` on the web) and `retry` loads the code again (the data is not read again).
  Turning `deferred` on therefore binds these views to a route that has no data, with the same rule:
  an inherited view must fit every route it covers. With a `data.dart` the code and the data load in
  parallel and `loading.dart` covers both waits.
- A function form works for both (`Widget loading()`,
  `Widget error({required Object error, required VoidCallback retry})`).
- **`keep_previous` and `data_retry` do not change which file is chosen**, only
  when it shows.

## `keep_previous` (default `true`)

`loading.dart` is **only for the first load.** Once the provider has a value or an
error, a reload (`ref.invalidate`, `refresh`, a section's dependencies changing)
**keeps rendering** it: the old page stays until the new value arrives, instead
of blinking to `loading.dart` and back. Off (`keep_previous: false`),
`loading.dart` shows whenever the provider is loading, refreshes included. This
is `skipLoadingOnReload` and `skipLoadingOnRefresh` on Riverpod's
`AsyncValue.when`, set by the generated `DataView(keepPrevious: ...)`. It applies
to a route's `data.dart` and a section's, including a provider you write
yourself.

## `data_retry` (default `inherit`)

Riverpod 3 **retries a failed provider on its own**, with backoff, and the app's
`ProviderScope(retry: ...)` or `ProviderContainer(retry: ...)` decides how. The
providers fespalier generates for `data()` functions set **no policy of their
own**, so the app's applies, and Riverpod's default (10 retries with doubling
delays, none for an `Error`) applies when the app sets none. To have a failure
settle into `error.dart` after a few attempts:

```dart
// lib/main.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

void main() => runApp(
  ProviderScope(
    retry: (retryCount, error) =>
        retryCount < 3 ? const Duration(seconds: 1) : null,
    child: MaterialApp.router(routerConfig: AppRoutes.router()),
  ),
);
```

- Together the two make `error.dart` show **as soon as `data.dart` fails, retrying
  or not**: a provider that failed and is being retried is `AsyncLoading` with
  its error still held, and with `keep_previous` on `DataView` shows that error,
  not `loading.dart`, for the whole retry window. It goes to the data when a
  retry succeeds and stays on the error when the policy gives up. With
  `keep_previous: false` a retry shows `loading.dart` again.
- **`data_retry: none`** gives every generated `data()` provider
  `retry: (retryCount, error) => null`, whatever the app's policy is: a failure
  is final until `error.dart`'s `retry` runs it again (how 0.1.1 behaved).
- A provider **you** write, or a **selector**, keeps the app's policy or its own
  `retry:`; `data_retry` does not apply to it.
- **Tests notice.** With the default `inherit` a failing `data.dart` runs more
  than once, so a test that counts calls or ends with a pending timer will see
  it. `pumpRouter` in `package:fespalier/testing.dart` defaults to **no retries**
  (see `fespalier-testing`).

```yaml
# pubspec.yaml
fespalier:
  data_retry: inherit   # inherit | none
  keep_previous: true   # true | false
```

## A route with a `freshness` or a `dataCache` (since 0.8.0)

Its `DataView` gets `keepDataOnError: true`: a reload that fails keeps the page on the value it had (the error is in
`XRoute.watch(ref).error`), and `error.dart` only shows when there is nothing to show, whatever `keep_previous`
says. And a value Riverpod's offline persistence restored (`isFromCache`) is shown while the fresh one loads, with
`keep_previous: false` too. See [`freshness-and-cache.md`](freshness-and-cache.md).

## Reloads from code

```dart
await ProductRoute(id: 42).refresh(ref);   // Re-runs data.dart; completes with the fresh value
ref.invalidate(ProductRoute.data(42));     // or invalidate the provider yourself
```

`refresh` on a function-form route is `ref.refresh(provider.future)`; on a
selector it invalidates and reads once (`refreshSelected`), so the selected
provider runs once. See `prefetch-and-lookup.md` for the other typed helpers.
