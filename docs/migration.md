# Migration

## Adopting fespalier in a go_router app

You do not have to move everything at once. fespalier can mount its generated routes inside the `GoRouter`
you already have, so you can bring one section of the app over at a time.

1. Install `fsp` and add the package ([Installation and setup](getting-started.md)).
2. Set `main: manual` in the `fespalier:` section of `pubspec.yaml`, so that `fsp` writes no `main()` of
   its own and your `main()` stays as it is ([`main()`](app-startup.md)).
3. Put the first routes under `lib/app/` and run `fsp gen` (or keep `fsp watch` running).
4. Mount the generated routes in your router. `at` is the URL prefix:

```dart
GoRouter(
  navigatorKey: rootKey,
  routes: [...yourRoutes, ...AppRoutes.mount(at: '/x', navigatorKey: rootKey)],
)
```

Pass `mount` your `GoRouter`'s own `navigatorKey`: routes that render on the
[root navigator](navigation.md#the-root-navigator-navigatordart) name it as their `parentNavigatorKey`,
which go_router requires to be an ancestor navigator's. (`AppRoutes.router()` takes a `navigatorKey:`
too, and either way the key is `AppRoutes.rootNavigatorKey`.)

## Upgrading

What changed between releases, newest first, each with a link to the reference section that describes the
behavior today.

There is no 0.8.0 release: it was tagged but never published (its binaries were built before the last
change), and the wave it carried ships as 0.8.1.

### 0.9.x

- **Page names** ([Transitions](layouts.md#transitions)). Every `pageBuilder:` the generated file writes
  is wrapped in `namedPage('/products/:id', () => ...)`, so a `NavigatorObserver` sees the pattern
  instead of `null` (a `remount` page used to be `:id`). Regenerate with `fsp gen`: every app's
  `app.g.dart` changes.
- **Telemetry** ([Spans around data() and actions](observability.md#spans-around-data-and-actions)).
  With `telemetry: true` the data provider calls
  `traceDataCall(ref, 'd4', id, () => data(ref, id: id), telemetry: ...)`.
  - A `data` span's duration includes the synchronous part of `data()`.
  - A `data()` that throws before it returns has a `data` span (before 0.9.0 it had none).
  - `FespalierOtel` makes data and action spans current. A sink with a member named `within` of another
    signature must rename it.
- **Hero shared elements** ([Shared elements (heroes)](layouts.md#shared-elements-heroes)): before 0.8.1 a
  `transition.dart` left the tree as it was; `heroes:` is opt-in.
- **Apps made with `fsp init` before 0.9.0**: see 0.8.1 for the `main()` change.

### 0.8.1

- **`main()`** ([`main()`: app.dart, startup.dart and splash.dart](app-startup.md)). Before 0.8.1
  `fsp init` printed a `main()` that built the `ProviderScope` and the `MaterialApp.router` itself. That
  still works, and it is what `main: manual` keeps. Nothing changes until you opt in; the table in
  [app-startup.md](app-startup.md) shows where each line of a hand-written `main()` goes.
- **Telemetry**: without `telemetry: true`, the generated file is exactly what it was before 0.8.1
  ([Turning it on](observability.md#turning-it-on)).
- **Heroes**: a layout's shell and a page keep the tree as it was before 0.8.1 unless a `transition.dart`
  passes `heroes:` ([Shared elements (heroes)](layouts.md#shared-elements-heroes)).

### 0.7.0

- **Deferred routes** ([Deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand)): a route
  that is not deferred generates exactly the code it did before 0.7.0.

### 0.6.0

- **`remount`** ([Remounting a page](navigation.md#remounting-a-page-remount)). `never` is what
  fespalier generated before 0.6.0, and the generated code keys a page by the URL where it used to use
  go_router's `state.pageKey`.
- **`disposeRouter`** ([pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation)): a
  test that disposes the router itself with an `addTearDown` registered before the call, as tests
  written for 0.4.x do, passes `disposeRouter: false`.

### 0.5.0

- **Guards and redirects** ([Guards](guards.md), [redirect.dart](guards.md#redirectdart)).
  - A guard may take `Ref ref` first and runs again when what it `ref.watch`es changes. Before 0.5.0 a
    guard read once, when you navigated; `ProviderContainer c` first is that older form, still read
    once.
  - A redirect may take `Ref ref` first, or `ProviderContainer c`.
  - Menus read the older form once, when the menu asks
    ([Menus and breadcrumbs](layouts.md#menus-and-breadcrumbs-navdart)).
  - See also the `guard.dart` row of [File kinds](file-kinds.md).
- **Layout restoration** ([State restoration](layouts.md#state-restoration)): a layout's page used the
  route object's hash code as its key, so a router built again by a hot reload or a test replaced the
  layout and lost its state. Since 0.5.0 it uses a `ValueKey` made of its restoration id.
- **Prefetch** ([From a location to its data](data.md#typed-helpers-on-the-route)): a prefetch used to
  lapse after 30 seconds without a `keepFor`, and now lasts until closed; `prefetchKeepAlive` is gone.
  `ref`, `keepFor`, `preload`, `of`, `maybeOf` and `copyWith` can no longer be segment or query names.
- **`pumpRouter`** ([pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation))
  disposes the router when the test ends, and the generated `AppRoutes` makes a fresh `navigatorKey` on
  each `router()` or `mount()` call without one.
