# Testing pitfalls

As of v0.4.0, observed against go_router 18.0.2, hooks_riverpod 3.4.3 and Flutter
3.47. Each one was hit while writing these skills.

The traps of the route smoke tests `fsp test` writes (since 0.8.0: a periodic timer in a fake, a failure that
names where the router ended) are in [`route-smoke-tests.md`](route-smoke-tests.md).

## `pumpRouter` and `currentLocation`

```dart
Future<ProviderContainer> pumpRouter(
  WidgetTester tester,
  GoRouter router, {
  List<Override> overrides = const [],
  ProviderContainer? container,
  bool settle = true,
  Duration? Function(int retryCount, Object error)? retry = _noRetry,
})

String currentLocation(WidgetTester tester)
```

- It wraps the router in a `ProviderScope` (an `UncontrolledProviderScope` over a
  container it creates, and disposes with `addTearDown`) and Flutter's
  `MaterialApp.router`, and returns the container.
- **It disposes the router when the test ends** (since 0.5.0). On 0.4.x and earlier the
  router was never disposed, and a test with `LeakTesting.enable()` failed with a
  `notDisposed` `GoRouterDelegate`; there, add `addTearDown(router.dispose)` yourself,
  and remove it when you move to 0.5.0 (a teardown registered before `pumpRouter` runs
  after its own, and a second `dispose` throws: _A GoRouteInformationProvider was used after
  being disposed_). Since 0.6.0 you can keep it and pass `disposeRouter: false` instead. A
  router you disposed in the test body is fine. Don't share a router between tests.
- **A guard that returns a `Future` costs a frame**, even `Future.value(...)`: the router
  waits for it, so the test (and a cold deep link) sees a blank first frame before the
  page. Return the `GuardResult` directly when nothing needs an `await`.
- **`overrides` and `container` are exclusive**: passing both trips an assertion
  (`pass overrides to your own ProviderContainer, or leave the container out`).
  A container you pass is **yours to dispose**.
- **`retry` defaults to no retries**, so a failing `data.dart` shows `error.dart` at
  once and leaves no timer behind, unlike a real app (whose generated providers keep
  Riverpod's automatic retry unless `data_retry: none`). Pass
  `retry: ProviderContainer.defaultRetry` (or your own function) to test what the
  app's retry policy does, and dispose the returned container before the test ends
  if that policy keeps retrying.
- **`settle: true`** (the default) is `pumpAndSettle`, which waits out `Future.delayed`
  in fakes. Turn it off to look at a loading view, then `pump` the time you want.
- **`Override` is not exported by `package:fespalier/fespalier.dart`.** Write the
  list inline (`overrides: [apiProvider.overrideWithValue(FakeApi())]`); to name
  the type, import it from `package:hooks_riverpod/misc.dart`.
- The app is **Flutter's `MaterialApp`**, which gives dialogs and sheets their
  `MaterialLocalizations`. With go_router 18, which looks for `package:material_ui`'s
  app, routes without a `transition.dart` do not animate in tests and go_router's own
  error screen is unstyled; with the root `transition.dart` that `fsp init` writes,
  no nested `material_ui` app is needed.

## Deferred routes: `pumpRouter` loads them, your own router must

Since 0.7.0 a route whose folder says `const deferred = true;` has its `page.dart` imported
`deferred as`. Loading it (`loadLibrary()`) always ends with a zero-duration `Timer`, which a
widget test's fake async never runs on its own: `pump()`, `pump(1µs)` and `pumpAndSettle()` leave it
pending, `pump(const Duration(seconds: 1))` happens to finish it, and the test ends with `A Timer
is still pending even after the widget tree was disposed`. Whether a test saw the page would
depend on what else pumped time. So:

- **`pumpRouter` loads the code of every deferred route first**, in `tester.runAsync`, which
  runs on the real event loop, and only then pumps. A deferred page is in the first settled frame,
  as an eager one is, and a test written for an app before it deferred anything passes unchanged.
  An app with no deferred route behaves exactly as before.
- **A test that pumps a router of its own does the same itself**, before `pumpWidget`:

```dart
await tester.runAsync(AppRoutes.loadDeferred);
await tester.pumpWidget(
  UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: AppRoutes.router(initialLocation: '/checkout')),
  ),
);
```

`AppRoutes.loadDeferred` is there when the app has a deferred route and works before any
`router()` call. Load only some with `DeferredLibrary.loadAll([...])`.

- **Forget it and a debug build throws**, rather than hang, a `FlutterError` when the page is
  built (`tester.takeException()` is it, and the page is not shown). It has three parts, here
  for a deferred `products/$id/page.dart`:
  - The summary: `The code of products/$id/page.dart is not loaded, and a widget test can't load it while it pumps.`
  - The description: `` `products/$id/page.dart` is a deferred route (`const deferred = true`): its `loadLibrary()` completes only on the real event loop, which `tester.pump()` doesn't run, so the page would show its loading view and leave a timer pending. ``
  - The hint: ``Boot the router with `pumpRouter`, which loads the code of every deferred route first, or call `await tester.runAsync(AppRoutes.loadDeferred)` before pumping a router of your own.``

  It is an `assert`: release builds and `flutter drive` / integration tests (a real event loop) are
  not affected.

- **The loading state of a real deferred page can't be observed** in a widget test (the code is
  loaded before the first frame). To test your own `loading.dart` and `error.dart` around a code
  load, build the view the generated file builds, with a library whose load you control:

```dart
final done = Completer<void>();
final library = DeferredLibrary(
  () => done.future,
  'x/page.dart',
  loadsInFakeAsync: true, // the load is yours, so a test may start it
);
// DeferredView(library: library, page: ..., loading: ..., error: (e, st, retry) => ...)
// pump: the loading view; done.complete(); pump(): the page.
```

A failed load shows `error.dart`, and its `retry` calls the library's load again.

## One router per test

A router **remembers where it went**: build a new one per test
(`AppRoutes.router(initialLocation: ...)`), never a shared `final`.

**Booting twice in one test** with fakes that use `Future.delayed` leaves timers from
the first tree behind; the test ends with `A Timer is still pending even after the
widget tree was disposed`. Boot once per test (a `for` loop of `testWidgets` is the
easy way), or `pumpAndSettle` between boots.

## `currentLocation` after a `push`

Since 0.4.0 `currentLocation` follows `go`, `pop` **and `push`**: after
`ProductRoute(id: 1).push(context)` it is `/products/1`, the top of the stack. It reads
the router's current configuration, because go_router keeps a pushed page out of
`routeInformationProvider.value`, which keeps showing the page underneath.

**On fespalier 0.3.0 and earlier it did not follow a `push`** (it read
`routeInformationProvider.value`): it still said where you were. On those versions read
the pushed route from the configuration instead:

```dart
router.routerDelegate.currentConfiguration.last.matchedLocation   // '/products/1'
```

## Timers and futures

- `await ProductRoute.read(ref, id: 1)` (or `refresh`) waits on the provider's real
  future, which waits on a fake clock in `testWidgets`: awaiting it first **hangs**.
  Start the future, `await tester.pump(duration)` past the fake's delay, then
  await it.
- `prefetch(ref, keepFor: duration)` holds a timer: `pump` past it, or pass
  `Duration.zero` (starts the load and keeps nothing). Since 0.5.0 the timer is
  cancelled when the widget behind `ref` is disposed; before, it stayed pending.
- A static `XRoute.watch(ref, ...)` is for `build`; calling it in a test body opens a
  subscription that leaves a timer pending. Read the provider through the container
  (`c.read(ProductRoute.data(1).future)`) instead.
- Go_router builds the **whole matched stack**: a deep link to `/products/2` also
  runs `/products`' `data.dart` underneath. If your fakes delay, pump long enough
  for both, or `pumpAndSettle`.

## Hovering a `RouteLink`

A `RouteLink` with `preload: Preload.intent` starts loading on a **mouse** hover, a
focus, or a pointer going down (0.5.0). A tap alone is a touch, which has no hover, so
to test the hover make a mouse pointer; to enter a link a second time, **leave it and
`pump` first**, or no second enter is dispatched:

```dart
final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
await mouse.addPointer(location: Offset.zero);
addTearDown(mouse.removePointer);
await mouse.moveTo(tester.getCenter(find.text('Product 2')));
await tester.pump();
expect(container.exists(ProductRoute.data(2)), isTrue);
```

- A link that is `tester.getCenter`-ed under another widget that fills the screen (a
  `Material` with tight constraints around a `ListTile`) covers the whole screen, so
  there is no outside to move to: align or size it.
- `Preload.visible` runs after a frame: `pump` once after the page shows or after a
  scroll. A provider released by a closed handle is gone one `pump` later.
- Read a link's `href` with `tester.widget<Link>(find.byType(Link)).uri`
  (`package:url_launcher/link.dart`). Details: `fespalier-routing`,
  [`links.md`](../../fespalier-routing/references/links.md).

## Getting a `WidgetRef` or a `BuildContext`

- A `BuildContext` under the router: `tester.element(find.byType(ProductPage))`, then
  `ProductsRoute().go(context)`.
- A `WidgetRef`: the element of a `ConsumerWidget`/`ConsumerStatefulWidget` **is**
  one: `tester.element(find.byType(ProductsPage)) as WidgetRef`. Use it for
  `prefetch`, `refresh`, `read`.
- The container `pumpRouter` returns: `c.read(session.notifier).signIn()`,
  `c.invalidate(CountRoute.data)`, `c.exists(ProductRoute.data(2))`.

## Importing files from `$` folders

An unescaped `$id` in an import is a Dart string-interpolation error
(`URIs can't use string interpolation`):

```dart
import 'package:my_app/app/products/\$id/page.dart';
```

## State restoration needs your own app

`pumpRouter` sets no `restorationScopeId`. For a restoration test build the router in
the `State` of a small app widget (so a restart makes a new one and only restored
state can put it back), give `MaterialApp.router` and `AppRoutes.router` scope ids,
and use `tester.restartAndRestore()`.

```dart
// lib/app/counter/page.dart
import 'package:flutter/material.dart';

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> with RestorationMixin {
  final _count = RestorableInt(0);

  @override
  String? get restorationId => 'counter';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) =>
      registerForRestoration(_count, 'count');

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => _count.value++),
    child: Text('count ${_count.value}'),
  );
}
```

```dart
// test/restoration_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

class RestorableApp extends StatefulWidget {
  const RestorableApp({super.key});

  @override
  State<RestorableApp> createState() => _RestorableAppState();
}

class _RestorableAppState extends State<RestorableApp> {
  // In State, not a `final`: a restart builds a new router.
  late final GoRouter router = AppRoutes.router(restorationScopeId: 'router');

  @override
  Widget build(BuildContext context) => ProviderScope(
    child: MaterialApp.router(restorationScopeId: 'app', routerConfig: router),
  );
}

void main() {
  testWidgets('the location and a page\'s state survive a restart', (
    tester,
  ) async {
    await tester.pumpWidget(const RestorableApp());
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.byType(Navigator).first)).go('/counter');
    await tester.pumpAndSettle();
    await tester.tap(find.text('count 0'));
    await tester.pump();
    await tester.tap(find.text('count 1'));
    await tester.pump();

    await tester.restartAndRestore();
    await tester.pumpAndSettle();

    expect(find.text('count 2'), findsOneWidget);
  });
}
```

Renaming a folder drops what was saved under its old id, once.

## A stale `app.g.dart` is not caught by `fsp check`

`fsp check` **writes and compares nothing**: it passes (exit 0) when `lib/app.g.dart`
is out of date. `flutter analyze` catches it only when code uses something the old
file lacks (`The function 'ExtraRoute' isn't defined`). To fail CI on a stale committed
file, regenerate and diff:

```sh
dart run fespalier gen
git diff --exit-code lib/app.g.dart
```

(`fespalier`'s own repository has a test that its committed example outputs are up to
date; your app needs the equivalent.)

## Tests may go to unknown paths

Since 0.7.0 `fsp` warns about a string path in `lib/` that matches no route
(``no route matches `/nope`, so it shows not-found [unknown_path]``), but it does **not**
read `test/`, `integration_test/` or `bin/`: a test that boots `AppRoutes.router(initialLocation:
'/nope')` to see `not_found.dart`, or mounts the tree under a prefix the app does not use, is
not flagged and needs no `fsp:ignore`.

## Leftovers

`flutter create` writes `test/widget_test.dart`, which refers to the `MyApp` you
replaced; `flutter analyze` fails on it until you delete or rewrite it.
