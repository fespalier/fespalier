# Testing recipes

As of v0.4.0, compiled and run against go_router 18.0.2, hooks_riverpod 3.4.3 and
Flutter 3.47. The app under test:

```dart
// lib/api.dart
import 'package:fespalier/fespalier.dart';

class Product {
  const Product(this.id, this.name);

  final int id;
  final String name;
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

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/api.dart';

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

```dart
// lib/app/products/$id/loading.dart
import 'package:flutter/material.dart';

class ProductLoading extends StatelessWidget {
  const ProductLoading({super.key});

  @override
  Widget build(BuildContext context) => const Text('loading');
}
```

```dart
// lib/app/products/$id/error.dart
import 'package:flutter/material.dart';

class ProductError extends StatelessWidget {
  const ProductError({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Text('failed: $error');
}
```

```dart
// lib/app/products/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => const ProductRoute(id: 1).go(context),
    child: const Text('first product'),
  );
}
```

## One test file

```dart
// test/products_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/api.dart';
import 'package:my_app/app.g.dart';
// A folder called $id: escape the dollar in an import, or Dart reads it as
// string interpolation.
import 'package:my_app/app/products/\$id/loading.dart';
import 'package:my_app/app/products/\$id/page.dart';
import 'package:my_app/app/products/page.dart';

class FakeApi implements Api {
  @override
  Future<Product> product(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (id == 13) throw StateError('no product 13');
    return Product(id, 'Fake $id');
  }
}

Future<ProviderContainer> boot(WidgetTester tester, String location) =>
    pumpRouter(
      tester,
      // A new router for every test: a router remembers where it went.
      AppRoutes.router(initialLocation: location),
      overrides: [apiProvider.overrideWithValue(FakeApi())],
    );

void main() {
  testWidgets('a deep link opens the page with its data', (tester) async {
    await boot(tester, '/products/2');
    expect(find.byType(ProductPage), findsOneWidget);
    expect(find.text('Fake 2'), findsOneWidget);
    expect(currentLocation(tester), '/products/2');
    // go_router builds the whole matched stack: /products is underneath.
    expect(find.text('first product', skipOffstage: false), findsOneWidget);
  });

  testWidgets('loading.dart first, then the page', (tester) async {
    // settle: false, so the loading view can be looked at.
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/2'),
      overrides: [apiProvider.overrideWithValue(FakeApi())],
      settle: false,
    );
    await tester.pump();
    expect(find.byType(ProductLoading), findsOneWidget);
    expect(find.byType(ProductPage), findsNothing);
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('Fake 2'), findsOneWidget);
  });

  testWidgets('a failing data.dart shows error.dart at once', (tester) async {
    await boot(tester, '/products/13');
    expect(find.text('failed: Bad state: no product 13'), findsOneWidget);
  });

  testWidgets('an unknown path and an unparsable segment are not found', (
    tester,
  ) async {
    await boot(tester, '/nope');
    expect(find.text('Nothing at /nope'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a bad segment never builds the page', (tester) async {
    await boot(tester, '/products/abc');
    expect(find.text('Nothing at /products/abc'), findsOneWidget);
    expect(find.byType(ProductPage), findsNothing);
  });

  testWidgets('typed navigation from a widget under the router', (
    tester,
  ) async {
    await boot(tester, '/products');
    await tester.tap(find.text('first product'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/products/1');
    expect(find.text('Fake 1'), findsOneWidget);
    // Or from any widget's context:
    ProductsRoute().go(tester.element(find.byType(ProductPage)));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/products');
  });

  test('locations, data and matches need no widgets', () {
    expect(const ProductRoute(id: 42).location, '/products/42');
    expect(
      AppRoutes.dataAt(Uri.parse('/products/42'))!.single,
      ProductRoute.data(42),
    );
    expect(AppRoutes.dataAt(Uri.parse('/products/abc')), isNull);
    final m = AppRoutes.match(Uri.parse('/products/42'))!;
    expect(m.params, {'id': 42});
    expect(m.info.path, '/products/:id');
  });

  testWidgets('currentLocation follows a push too', (tester) async {
    final router = AppRoutes.router(initialLocation: '/products');
    await pumpRouter(
      tester,
      router,
      overrides: [apiProvider.overrideWithValue(FakeApi())],
    );
    const ProductRoute(id: 1).push(tester.element(find.byType(ProductsPage)));
    await tester.pumpAndSettle();
    // The pushed route is the top of the stack, so it is the location (0.4.0).
    expect(currentLocation(tester), '/products/1');
    expect(
      router.routerDelegate.currentConfiguration.last.matchedLocation,
      '/products/1',
    );
    router.pop();
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/products');
  });
}
```

## A deferred route (since 0.7.0)

With `const deferred = true;` in `lib/app/products/\$id/route.dart`, the recipes above need no
change: `pumpRouter` loads the page's code first, so `find.byType(ProductPage)` finds it in the
first settled frame. A test that pumps its own router calls `loadDeferred` itself:

```dart
testWidgets('a deferred page, with a router of my own', (tester) async {
  final container = ProviderContainer(
    overrides: [apiProvider.overrideWithValue(FakeApi())],
  );
  addTearDown(container.dispose);
  final router = AppRoutes.router(initialLocation: '/products/2');
  addTearDown(router.dispose);

  // `loadLibrary()` completes only on the real event loop, which `pump` never runs.
  await tester.runAsync(AppRoutes.loadDeferred);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(ProductPage), findsOneWidget);
});
```

`preload` of a deferred route starts its code as well as its data
(`ProductRoute(id: 2).preload(ref)`); both are loaded after the same `pump`.

## Signed-in routes (since 0.9.0)

With `package:fespalier_auth`, `fakeAuth` is the `overrides` of `pumpRouter`. The guards, the sign-in form, the
API call and these tests are a compiling starter in
[`fespalier-guards`](../../fespalier-guards/references/auth-package.md), whose `test/auth_test.dart` has all
of the following as running samples.

```dart
// signed in as ada (an admin), on a fake backend and a memory store: no startup(), no network
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/admin'),
  overrides: fakeAuth(signedInAs: const AuthUser(id: 'ada', roles: {'admin'})),
);
expect(currentLocation(tester), '/admin');

// signed out: a guarded route asks for sign-in, and remembers where
await pumpRouter(tester, AppRoutes.router(initialLocation: '/orders'), overrides: fakeAuth());
expect(currentLocation(tester), '/sign-in?from=%2Forders');

// a pending sign-in: the fake backend holds the call on a Completer
final backend = FakeAuthBackend()..gate = Completer<void>();
// ...enter text, tap, `await tester.pump()`, look at 'Signing in...', then:
backend.gate!.complete();
await tester.pumpAndSettle();
```

- `fakeAuth({signedInAs, backend, store, apiOrigins, client, tokenLifetime})`: `client` is a `MockClient` for
  `authHttpClient` (the API calls), `apiOrigins` says which hosts get the token, `tokenLifetime` makes the
  session expire against the fake clock (call `fakeAuth` inside the test body, where that clock starts).
- `FakeAuthBackend` counts `signIns`, `refreshes` and `signOuts`, and fails with `signInError` (thrown by the
  next sign-in: `AuthCancelled()`, `FieldErrors({...})`, `AuthRejected()`) or `refreshError` (every refresh
  until cleared: `AuthRejected()` ends the session, anything else keeps it).
- In `fsp test`'s `test/routes/setup.dart`, `List<Override> overrides(String pattern) =>
fakeAuth(signedInAs: ...)` makes every guarded route render (otherwise a guarded route is skipped).
- `RecordingTelemetry` sees the `auth` spans: `#2 start auth refresh backend=fake trigger=expired`.

## Network images (since 0.9.0)

With `package:fespalier_image`, a test that shows an image needs `FakeImages`, or it goes through flutter_test's fake
`HttpClient` (every request a 400, with its own warning) and, with no CDN configured, prints the "not a URL" message.
`FakeImages(image: await createTestImage())` (made once, in `setUpAll`) completes every load in the frame that asks for it;
without `image:` a load waits for `fakes.complete(url, image)` or `fakes.fail(url)`. `fakes.cdn(yourCdn)` is your real CDN
loading through the fakes, so `fakes.requested` holds the exact URLs of your builder. Put the override in
`pumpRouter(overrides:)` **and** in `test/routes/setup.dart`'s `overrides(pattern)`.

```dart
final fakes = FakeImages(image: image);
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/products'),
  overrides: [imageCdnProvider.overrideWithValue(fakes.cdn(shopImages))],
);
expect(fakes.requested, hasLength(3)); // one URL per row, at the row's bucket
```

`cdn.resolve(source, logicalWidth: ..., devicePixelRatio: ...)` answers the size rule without a widget. A compiling
sample, and the rest (precache, heroes), is in [`fespalier-images`](../../fespalier-images/references/integration.md).

## Sentry events (since 0.9.0)

With `package:fespalier_sentry`, `RecordingSentry` (`package:fespalier_sentry/testing.dart`) is a real Sentry `Hub` whose
transport keeps what it would send: no `SentryFlutter.init`, no native SDK, no network, no timer. Give its hub to the sink
and read what the SDK built after a `pump` (the SDK hands an event to its transport a few microtasks later):

```dart
final sentry = RecordingSentry();
FespalierTelemetry.install(FespalierSentry(hub: sentry.hub));
await pumpRouter(tester, AppRoutes.router(initialLocation: '/orders/1'));
await tester.tap(find.text('Refuse'));
await tester.pumpAndSettle();
await tester.pump();
expect(await sentry.lines(), [
  r'event StateError operation=action route=/orders/:id file=orders/$id/action.dart action=refuse',
]);
expect(sentry.breadcrumbs, ['navigation enter /orders/:id']);
```

`sent()` is the JSON (tags, fingerprint, contexts, measurements); `tags`, `transactionName` and `rawBreadcrumbs` read the scope.
By default the sink sends no transaction, so a test of `tracing: true` navigates after the first screen (on Android and
iOS, which is what `defaultTargetPlatform` says in a test, Sentry's app start owns the first one; pass
`platform: TargetPlatform.linux` to `FespalierSentry`). A container-only test (an action, `data()`) is a plain `test()`:
a `ProviderContainer` read inside `testWidgets` leaves a Riverpod timer pending, and a real `Future.delayed(Duration.zero)`
stands in for `pump`. A plain `SentryNavigatorObserver` starts a timer: bind a transaction to the hub's scope by hand
instead. `debugPrint` is a foundation debug variable: put it back before the test body ends, not in `tearDown`.
[`fespalier-observability`](../../fespalier-observability/references/sentry.md) has the rest.

## DPoP proofs (since 0.9.0)

With `package:fespalier_sign_keypair`, a test needs no secure element: `DpopProof(signer: FakeDpopSigner())` is a proof
maker over a software key from a fixed scalar (the same key and signature on every run; `deleteKey`, which sign-out
calls, moves to the next key), and `verifyDpopProof(proof, method:, uri:, accessToken:, nonce:, thumbprint:, now:)`
(from `package:fespalier_sign_keypair/testing.dart`) is what a fake server checks each proof with: it throws a
`DpopProofInvalid` that names the first check that failed (`htm is GET, not POST`, `ath does not match the access
token`, `iat is 120 s from now`). It does not remember `jti`s: a fake server keeps a `Set` and refuses a repeat, which is
how a `RetryClient` under the session client shows up. Call `DpopProof` inside the test body so `clock` is the test's;
`withClock(Clock.fixed(...), ...)` pins `iat`. The whole story, against the demo server, is `examples/auth/test/dpop_test.dart`
(a nonce challenge, a clock two minutes behind, a refresh with the same key, a rotated key, `keyLost`); a compiling sample
is in [`fespalier-guards`](../../fespalier-guards/references/auth-dpop.md).

## A form and its pending state (since 0.8.1)

A form's save is held on a `Completer` and the test pumps by frames: no timer, no `runAsync`.
The page and its `action.dart` are in `fespalier-data`, `references/forms-and-optimistic.md`,
which has this test as a compiling sample.

```dart
final api = ProfileApi()..gate = Completer<void>();           // the fake backend holds the save
await pumpRouter(tester, AppRoutes.router(initialLocation: '/nickname'),
    overrides: [profileApiProvider.overrideWithValue(api)]);
await tester.enterText(find.byType(TextField), 'Bob');         // types into the field's controller
await tester.tap(find.text('Save'));
await tester.pump();
expect(find.text('Saving...'), findsOneWidget);                 // pending: onSubmit is null
expect(find.text('Hello Bob'), findsOneWidget);                 // the optimistic patch, at once
api.gate!.complete();
await tester.pump();                                            // then assert the server's value
```

## An adaptive layout (since 0.9.0)

With `package:fespalier_adaptive`, the component follows the window's width, and **Flutter's default test window is
800 x 600 logical pixels: a rail with the default breakpoints** (a bar with `NavBreakpoints(rail: 840)`, what
`examples/tabs` uses). Size the window with `tester.view`, and reset it:

```dart
tester.view.physicalSize = const Size(400, 900); // a bar; 700 is a rail, 1300 a drawer
tester.view.devicePixelRatio = 1;
addTearDown(tester.view.reset);
await pumpRouter(tester, AppRoutes.router(initialLocation: '/search'));
expect(find.byType(NavigationBar), findsOneWidget);

tester.view.physicalSize = const Size(1300, 900); // resize in the same test
await tester.pumpAndSettle();
expect(find.byType(NavigationDrawer), findsOneWidget);
```

A tab's state survives the resize, so a test can count on the counter it tapped before it. The model alone needs no
widget: `AdaptiveNav(menu: items, width: 1300)` with `NavItem`s built by hand. A compiling test is in
[`fespalier-layouts`](../../fespalier-layouts/references/adaptive-layouts.md).
