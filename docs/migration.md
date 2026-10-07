# Migration

## Adopting fespalier in a go_router app

You do not have to move everything at once: fespalier can mount its generated routes inside the `GoRouter` you already have, so you can bring one section of the app over at a time.

1. Install `fsp` and add the package ([Installation and setup](getting-started.md)).
2. Set `main: manual` in the `fespalier:` section of `pubspec.yaml`, so that `fsp` writes no `main()` of its own and your `main()` stays as it is ([`main()`](app-startup.md)).
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

What changed between releases, newest first, each with a link to the reference section that describes the behavior today. There is no 0.8.0 release: it was tagged but never published, and the wave it carried ships as 0.8.1.

### 0.12.0

- **`ready()` and `attach()` in startup.dart** ([`main()`](app-startup.md)). Opt-in, and an app that exports
  neither regenerates to the same `lib/app.main.g.dart` and the same `StartupGate`. `ready(ProviderContainer)`
  runs on the app's own container after `startup()` and before the router; `attach(GoRouter, ProviderContainer)`
  runs after the first frame that shows the router, after the adapters'. They are what a `main: manual` app
  that builds its own `ProviderContainer` writes in its `main()`; moving to the generated `main()` is moving
  that code into them. Run `fsp gen` after adding either. **`ready` and `attach` are reserved names in startup.dart now**: a helper of that name with another shape is an `fsp` error (`ready` takes one `ProviderContainer`, optional or nullable allowed, and returns `void`, `Future<void>` or `FutureOr<void>`; `attach` takes `GoRouter` and `ProviderContainer`, returns `void` and is not `async`): rename it or make it private.

### 0.11.0

- **Forms moved to the `fespalier_forms` package** ([Forms](forms.md)). `form()` and `useForm` need the
  `fespalier_forms` package. Add `fespalier_forms` under `dependencies:`, at the same git `url` and `ref` as
  `fespalier`, and run `fsp gen`: `app.g.dart` now imports `package:fespalier_forms/fespalier_forms.dart`
  (only in an app with a `form()`), and `fsp` reports an error at each `form()` until the dependency is there.
  Code that names `ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`, `FieldCodec`,
  `ActionFormMessages`, `ActionFormValidation` or `useActionForm` imports
  `package:fespalier_forms/fespalier_forms.dart`: `package:fespalier` no longer exports them. The names and
  the behaviour are the same, and so is a page that only calls the generated `useForm`.
  `FieldErrors`, `validate()` and `optimistic()` stay in `fespalier` ([`validate()` and
  `FieldErrors`](actions.md#validate-and-fielderrors)): an app with no form changes nothing. In a repository
  checkout, `examples/features` and `examples/auth` show the dependency.
- **Drafts** ([Drafts](forms.md#drafts)). A form can keep what the user typed per route and restore it on return:
  `NicknameRoute.useForm(ref, data: p, draft: const FormDraft())`. It is opt-in, so no form changes behaviour, but
  every app with a `form()` regenerates `app.g.dart`: `useForm` takes a `FormDraft? draft` and passes the action's
  file and name, its keys and the form's field types to `useActionForm`, and a `bool`, `DateTime` or enum field gets a
  `DraftCodec`. A key of an action with a form can no longer be called `draft`. Drafts go to `formDraftStorage`, which
  is your `dataCacheStorage` unless you override it; call `clearFormDrafts` when somebody signs out.
- **Asking before unsaved changes go** ([Leaving with unsaved changes](forms.md#leaving-with-unsaved-changes)). A
  `leave.dart` that is `leaveIfClean(context, ref, page)` asks in a bottom sheet ("Keep editing", "Discard", and
  "Keep as draft" for a form with a `draft:`), and a `useForm` under a page with a `leave.dart` is the page's
  `LeaveSource` by itself. Nothing changes for an app that has no `leave.dart` (and `app.g.dart` is the same). Flutter's
  `MaterialLocalizations` are needed by the sheet: on material_ui's `MaterialApp`, override `leavePrompt`.
- **Multi-page forms** ([Multi-page forms](forms.md#multi-page-forms)). A section's `action.dart` with a `const steps`
  map is a form over several pages that share one form and one draft. It is new and opt-in: no app changes unless it
  adds one. Only a `const` map literal called `steps` (or `<action>Steps`) in an `action.dart` with a `form()` is read as one;
  a `steps` of another shape (a number, a list) is left alone. A page-less section may now
  have a `leave.dart` when it is a flow, `leaveExit` gets a `within:` there, and a `LeaveScope.onBack` handler now
  blocks the pop on the first page of a navigator too (a step of a flow is the only page of its shell's navigator).

- **A guard above a tab layout runs once, on the tab shell** (`StatefulShellRoute.redirect`), instead of being copied into each tab's route. What it decides is the same (it still runs for every location under the tabs, before the tab's own guards), but its telemetry and DevTools site is now one, named after the tab folder (`g<guard>@<tab folder>`: the `fespalier.route` of its spans is the folder's pattern, `/` for a group, not each tab's), so a dashboard that groups guard outcomes by `fespalier.route` sees the tabs merged. Run `fsp gen`; an app with no guard above its tabs changes nothing.

- **`observe.dart`'s `onEnter` can take a `RouteScope`** ([The page's scope](observability.md#the-pages-scope-routescope)).
  `RouteHooks.onEnter` is `void Function(Ref ref, RouteScope scope)?` now: every app with an `observe.dart`
  regenerates (`fsp gen`), because the generated closures read `onEnter: (ref, scope) => ...`. A hook
  you wrote keeps compiling unchanged; one that builds a `RouteHooks` by hand takes two parameters.
  `onEnter(Ref ref, {required RouteScope scope})` may call `scope.hold(provider)` (kept loaded until the
  page is gone, a parked tab included) and `scope.onLeave(callback)`. `AppRoutes.attach` takes the
  app's `ProviderContainer` in an app with an `observe.dart` too: `lib/app.main.g.dart` now gives the
  `StartupGate` `attach: AppRoutes.attach` (regenerate it with `fsp gen`), and the hooks run in the app's root
  container, where a provider overridden only in a nested `ProviderScope` reads its default.
  A scope ends, and its `onLeave` callbacks run, when its container is disposed.
  **Page ids changed for `replace`:** the lifecycle (`observe.dart`, telemetry, Sentry breadcrumbs) told a page made by
  `replace` apart by a random key, and now by the key of the page it replaces. `replace('/c/1?q=2')` on the tree page
  `/c/1` is no longer a leave and an enter; `replace('/c/2')` still is, and so are `push` and `pushReplacement`.

### 0.9.x

- **Page names** ([Transitions](layouts.md#transitions)). Every `pageBuilder:` the generated file writes
  is wrapped in `namedPage('/products/:id', () => ...)`, so a `NavigatorObserver` sees the pattern
  instead of `null` (a `remount` page used to be `:id`). Regenerate with `fsp gen`: every app's
  `app.g.dart` changes.
  **Telemetry** ([Spans around data() and actions](observability.md#spans-around-data-and-actions)). With `telemetry: true` the data provider calls `traceDataCall(ref, 'd4', id, () => data(ref, id: id), telemetry: ...)` (one closure per provider build, no `Future` and no microtask); regenerate with `fsp gen`. An app without `telemetry: true` keeps `traceData(...)`, and its file does not change.
  - A `data` span starts before `data()` runs, so its duration includes the synchronous part.
  - A `data()` that throws before it returns has a `data` span (before 0.9.0 it had none).
  - `FespalierOtel` makes data and action spans current, so the HTTP spans of `otel_http` and `otel_dio` are their children. A sink with a member named `within` of another signature must rename it.

### 0.8.1

- **`main()`** ([`main()`: app.dart, startup.dart and splash.dart](app-startup.md)). Before 0.8.1
  `fsp init` printed a `main()` that built the `ProviderScope` and the `MaterialApp.router` itself. That
  still works, and it is what `main: manual` keeps. Nothing changes until you opt in; the table in
  [app-startup.md](app-startup.md) shows where each line of a hand-written `main()` goes.
  **Telemetry** ([Turning it on](observability.md#turning-it-on)): without `telemetry: true` nothing is generated for it.

### 0.7.0

- **Deferred routes** ([Deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand)): a route
  that is not deferred generates exactly the code it did before 0.7.0.

### 0.6.0

- **`remount`** ([Remounting a page](navigation.md#remounting-a-page-remount)). `never` is what
  fespalier generated before 0.6.0, and the generated code keys a page by the URL where it used to use
  go_router's `state.pageKey`.
  **`disposeRouter`** ([pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation)): a test that disposes the router itself with an `addTearDown` registered before the call, as tests written for 0.4.x do, passes `disposeRouter: false`.
- **`replace`** ([The URL as state](navigation.md#the-url-as-state-of-and-copywith)) now shows its location in the address bar and replaces the history entry; on 0.5.0 it was go_router's in every case (the address bar followed it only when no page was below it), so use `go` for URL state there.

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
  **Prefetch** ([Typed helpers on the route](data.md#typed-helpers-on-the-route)): a prefetch used to lapse after 30 seconds without a `keepFor`, and now lasts until closed; `prefetchKeepAlive` is gone. `ref`, `keepFor`, `preload`, `of`, `maybeOf` and `copyWith` can no longer be segment or query names.
- **`pumpRouter`** ([pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation))
  disposes the router when the test ends, and the generated `AppRoutes` makes a fresh `navigatorKey` on
  each `router()` or `mount()` call without one.
