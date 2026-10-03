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
