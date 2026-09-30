// The typed data helpers on the generated routes: watch, read and prefetch.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:shop/app/layout.dart';

/// The static type of the expression it's given: `dynamic` if inference failed.
Type staticType<T>(T value) => T;

typedef WatchProduct = AsyncValue<Product> Function(WidgetRef ref,
    {required int id});
typedef ReadProduct = Future<Product> Function(WidgetRef ref, {required int id});
typedef WatchProducts = AsyncValue<List<Product>> Function(WidgetRef ref);
typedef ReadProducts = Future<List<Product>> Function(WidgetRef ref);

class CountingApi extends FakeApi {
  var productCalls = 0;

  @override
  Future<Product> product(int id) {
    productCalls++;
    return super.product(id);
  }
}

/// A WidgetRef that outlives the test's taps: the root layout's own.
WidgetRef rootRef(WidgetTester tester) =>
    tester.element(find.byType(AppLayout)) as WidgetRef;

void main() {
  test('the helpers are typed by what data.dart yields, not dynamic', () {
    // If inference gave `dynamic`, these types would differ.
    expect(staticType(ProductRoute.watch), WatchProduct);
    expect(staticType(ProductRoute.read), ReadProduct);
    expect(staticType(ProductsRoute.watch), WatchProducts);
    expect(staticType(ProductsRoute.read), ReadProducts);
  });

  group('read', () {
    testWidgets('completes with the typed value, loading it once',
        (tester) async {
      final api = CountingApi();
      await pumpRouter(
        tester,
        AppRoutes.router(),
        overrides: [apiProvider.overrideWithValue(api)],
      );
      final product = ProductRoute.read(rootRef(tester), id: 2);
      await tester.pump(const Duration(seconds: 1));
      expect((await product).name, 'Ceramic mug');
      expect(api.productCalls, 1);
    });

    testWidgets('an error is thrown to the caller', (tester) async {
      await pumpRouter(tester, AppRoutes.router());
      final product = ProductRoute.read(rootRef(tester), id: 99);
      // Hand the future its handler before time passes, so the error isn't unhandled.
      final caught = expectLater(product, throwsA(isA<ProductNotFound>()));
      await tester.pump(const Duration(seconds: 1));
      await caught;
    });
  });

  testWidgets('watch is the provider the page watches', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final products = ProductsRoute.watch(ref);
              final one = ProductRoute.watch(ref, id: 2);
              return Text('${products.value?.length} ${one.value?.name}');
            },
          ),
        ),
      ),
    );
    expect(find.text('null null'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('4 Ceramic mug'), findsOneWidget);
  });

  group('prefetch', () {
    testWidgets('the page opens with the data already loaded', (tester) async {
      final api = CountingApi();
      await pumpRouter(
        tester,
        AppRoutes.router(),
        overrides: [apiProvider.overrideWithValue(api)],
      );
      final handle = const ProductRoute(id: 2).prefetch(rootRef(tester));
      await tester.pump(const Duration(seconds: 1));

      ProductRoute(id: 2).go(tester.element(find.text('Browse products')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The price is only on the product page; the list below it is still loading.
      expect(find.text('€12.00'), findsOneWidget);
      expect(api.productCalls, 1);
      await tester.pump(const Duration(seconds: 1));
      // The handle keeps the data for as long as the app wants; nothing else waits.
      handle.close();
      // Let what is still loading (the list behind the page) finish.
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the handle keeps the data until it is closed', (tester) async {
      final api = CountingApi();
      final container = await pumpRouter(
        tester,
        AppRoutes.router(),
        overrides: [apiProvider.overrideWithValue(api)],
      );
      final handle = const ProductRoute(id: 2).prefetch(rootRef(tester));
      await tester.pump(const Duration(minutes: 2));
      expect(container.exists(ProductRoute.data(2)), isTrue);

      handle.close();
      await tester.pump();
      expect(container.exists(ProductRoute.data(2)), isFalse);
    });

    testWidgets('without it the same navigation shows loading first',
        (tester) async {
      await pumpRouter(tester, AppRoutes.router());
      ProductRoute(id: 2).go(tester.element(find.text('Browse products')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('€12.00'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('€12.00'), findsOneWidget);
    });

    testWidgets('the data is dropped after keepFor', (tester) async {
      final api = CountingApi();
      final container = await pumpRouter(
        tester,
        AppRoutes.router(),
        overrides: [apiProvider.overrideWithValue(api)],
      );
      const ProductRoute(id: 2)
          .prefetch(rootRef(tester), keepFor: const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(container.exists(ProductRoute.data(2)), isTrue);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(container.exists(ProductRoute.data(2)), isFalse);
    });

    testWidgets('a failed prefetch is not kept', (tester) async {
      final api = CountingApi();
      final container = await pumpRouter(
        tester,
        AppRoutes.router(),
        overrides: [apiProvider.overrideWithValue(api)],
      );
      final handle = const ProductRoute(id: 99).prefetch(rootRef(tester));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(container.exists(ProductRoute.data(99)), isFalse);
      expect(handle.isClosed, isTrue);
    });
  });
}
