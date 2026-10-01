# Testing pitfalls

As of v0.4.0, observed against go_router 18.0.2, hooks_riverpod 3.4.3 and Flutter
3.47. Each one was hit while writing these skills.

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
  after its own, and a second `dispose` throws). A router you disposed in the test body is
  fine. Don't share a router between tests.
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

## Leftovers

`flutter create` writes `test/widget_test.dart`, which refers to the `MyApp` you
replaced; `flutter analyze` fails on it until you delete or rewrite it.
