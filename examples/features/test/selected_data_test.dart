// A data.dart that selects a provider the app already has (a hand-written family
// in lib/catalog.dart standing in for a riverpod_generator one), instead of
// wrapping it: one fetch per navigation, refresh through the selected provider,
// and the app's own retry policy on it.
import 'package:features/app.g.dart';
import 'package:features/app/catalog/\$productId/data.dart' as product_data;
import 'package:features/catalog.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Duration? noRetry(int retryCount, Object error) => null;

Future<void> boot(
  WidgetTester tester,
  String location, {
  Duration? Function(int retryCount, Object error)? retry = noRetry,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      retry: retry,
      child: MaterialApp(
        home: mui.MaterialApp.router(
          routerConfig: AppRoutes.router(initialLocation: location),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The DataView's own WidgetRef: it lives as long as the route is on screen.
WidgetRef viewRef<T>(WidgetTester tester) =>
    tester.element(find.byType(DataView<T>)) as WidgetRef;

/// The static type of the expression it's given: `dynamic` if inference failed.
Type staticType<T>(T value) => T;

typedef WatchProduct = AsyncValue<Product> Function(
  WidgetRef ref, {
  required String productId,
});
typedef ReadProduct = Future<Product> Function(
  WidgetRef ref, {
  required String productId,
});

void main() {
  setUp(() {
    productFetches = 0;
    featuredFetches = 0;
    reviewFetches = 0;
    flakyRuns = 0;
  });

  test('the data.dart function is the selector the app wrote', () {
    // The route's `data` returns the selected provider, not one of its own.
    expect(ProductDetailRoute.data('1'), productProvider('1'));
    expect(ProductDetailRoute.data('1'), isNot(productProvider('2')));
    expect(product_data.data(productId: '1'), productProvider('1'));
    expect(CatalogRoute.data, same(featuredProvider));
    expect(
      ReviewsRoute.data((productId: 'a', page: 2)),
      reviewsProvider((productId: 'a', page: 2)),
    );
  });

  test(
    'the typed helpers are typed by the AsyncValue<T> that was selected',
    () {
      expect(staticType(ProductDetailRoute.watch), WatchProduct);
      expect(staticType(ProductDetailRoute.read), ReadProduct);
    },
  );

  testWidgets('one fetch per navigation, and loading.dart before it', (
    tester,
  ) async {
    await boot(tester, '/catalog/1');
    expect(find.text('Loading product'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Product 1'), findsOneWidget);
    expect(find.text('Loading product'), findsNothing);
    // Not two: no wrapper provider in front of productProvider.
    expect(productFetches, 1);
    await tester.pump(const Duration(seconds: 60));
    expect(productFetches, 1);
  });

  testWidgets('a route without keys selects the provider itself', (
    tester,
  ) async {
    await boot(tester, '/catalog');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Featured: alpha, beta'), findsOneWidget);
    expect(featuredFetches, 1);
  });

  testWidgets('a segment and a query parameter key a record family', (
    tester,
  ) async {
    await boot(tester, '/catalog/7/reviews?page=2');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('7 review, page 2'), findsOneWidget);
    expect(reviewFetches, 1);
    expect(
      const ReviewsRoute(productId: '7', page: 2).location,
      '/catalog/7/reviews?page=2',
    );
  });

  group('refresh', () {
    testWidgets('re-runs the selected provider once, keeping the old page up', (
      tester,
    ) async {
      await boot(tester, '/catalog/1');
      await tester.pump(const Duration(milliseconds: 50));
      expect(productFetches, 1);

      final done = const ProductDetailRoute(productId: '1')
          .refresh(viewRef<Product>(tester));
      await tester.pump();
      // keep_previous: the old value stays, loading.dart doesn't blink in.
      expect(find.text('Loading product'), findsNothing);
      expect(find.text('Product 1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      await done;
      expect(productFetches, 2);
      expect(find.text('Product 1'), findsOneWidget);
      await tester.pump(const Duration(seconds: 60));
      expect(productFetches, 2);
    });

    testWidgets('on a route without keys', (tester) async {
      await boot(tester, '/catalog');
      await tester.pump(const Duration(milliseconds: 50));
      final done = const CatalogRoute().refresh(viewRef<List<String>>(tester));
      await tester.pump(const Duration(milliseconds: 50));
      await done;
      expect(featuredFetches, 2);
    });

    testWidgets("error.dart's retry runs the selected provider again", (
      tester,
    ) async {
      await boot(tester, '/catalog/bad');
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.text('Product failed: Exception: no product bad'),
        findsOneWidget,
      );
      final before = productFetches;
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('Loading product'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      // The selected provider ran again, with nothing wrapped around it.
      expect(productFetches, greaterThan(before));
      expect(
        find.text('Product failed: Exception: no product bad'),
        findsOneWidget,
      );
    });
  });

  group("the app's own retry policy on the selected provider is what runs", () {
    const failed = 'Product failed: Exception: no product bad';

    testWidgets('productProvider retries twice, whatever the scope says', (
      tester,
    ) async {
      // The scope's policy is "never retry"; the provider's own says twice.
      await boot(tester, '/catalog/bad');
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text(failed), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(productFetches, 3);
      expect(find.text(failed), findsOneWidget);
      await tester.pump(const Duration(minutes: 2));
      expect(productFetches, 3);
    });

    testWidgets("and wins over Riverpod's default policy too", (tester) async {
      await boot(tester, '/catalog/bad', retry: null);
      await tester.pump(const Duration(seconds: 30));
      expect(productFetches, 3);
      expect(find.text(failed), findsOneWidget);
    });

    testWidgets('error.dart stays up through the retries, then the data', (
      tester,
    ) async {
      // Fails runs 1 and 2, succeeds on the third.
      await boot(tester, '/catalog/flaky');
      expect(find.text('Loading product'), findsOneWidget);
      var errors = 0;
      for (var ms = 10; ms <= 400; ms += 10) {
        await tester.pump(const Duration(milliseconds: 10));
        expect(find.text('Loading product'), findsNothing, reason: 'at $ms ms');
        if (find.textContaining('Product failed:').evaluate().isNotEmpty) {
          errors++;
        }
      }
      expect(flakyRuns, 3);
      expect(errors, greaterThan(15));
      expect(find.text('Product flaky'), findsOneWidget);
    });
  });

  group('the typed helpers', () {
    testWidgets('read completes with the value, running the provider once', (
      tester,
    ) async {
      await boot(tester, '/catalog');
      await tester.pump(const Duration(milliseconds: 50));
      final product = ProductDetailRoute.read(
        viewRef<List<String>>(tester),
        productId: '3',
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect((await product).name, 'Product 3');
      expect(productFetches, 1);
    });

    testWidgets('prefetch warms the provider the page then watches', (
      tester,
    ) async {
      await boot(tester, '/catalog');
      await tester.pump(const Duration(milliseconds: 50));
      const ProductDetailRoute(productId: '2')
          .prefetch(viewRef<List<String>>(tester));
      await tester.pump(const Duration(milliseconds: 50));
      expect(productFetches, 1);

      const ProductDetailRoute(productId: '2')
          .go(tester.element(find.byType(DataView<List<String>>)));
      await tester.pumpAndSettle();
      expect(find.text('Product 2'), findsOneWidget);
      // Navigating found the prefetched value: still one fetch.
      expect(productFetches, 1);
      await tester.pump(const Duration(seconds: 31));
    });
  });

  testWidgets('a listenable that is not a provider says so when refreshed', (
    tester,
  ) async {
    await boot(tester, '/catalog');
    await tester.pump(const Duration(milliseconds: 50));
    final ref = viewRef<List<String>>(tester);
    final selected = featuredProvider.select((value) => value);
    expect(
      () => ref.invalidateSelected(selected),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cannot be invalidated'),
        ),
      ),
    );
    expect(() => ref.refreshSelected(selected), throwsA(isA<StateError>()));
    expect(() => ref.readSelected(selected), throwsA(isA<StateError>()));
  });
}
