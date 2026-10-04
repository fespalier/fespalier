// Old data stays on screen while data.dart refreshes (keep_previous), and this
// example's `data_retry: none`: a failure is not retried behind the scenes.
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:shop/app/products/loading.dart';
import 'images.dart';

class CountingApi extends FakeApi {
  var productCalls = 0;

  @override
  Future<Product> product(int id) {
    productCalls++;
    return super.product(id);
  }
}

void main() {
  testWidgets('invalidating a loaded route never shows loading.dart', (
    tester,
  ) async {
    final api = CountingApi();
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/2'),
      overrides: [apiProvider.overrideWithValue(api), fakeImages()],
      settle: false,
    );
    expect(find.byType(ProductsLoading), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Ceramic mug'), findsOneWidget);
    expect(api.productCalls, 1);

    container.invalidate(ProductRoute.data(2));
    // Every frame of the reload (the fake takes 500 ms): old data, no skeleton.
    for (var t = 100; t <= 600; t += 100) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ProductsLoading), findsNothing, reason: 'at $t ms');
      expect(find.text('Ceramic mug'), findsOneWidget, reason: 'at $t ms');
    }
    expect(api.productCalls, 2);

    // Refreshing through the provider does the same, and completes with the value.
    final refreshed = container.refresh(ProductRoute.data(2).future);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ProductsLoading), findsNothing);
    expect(find.text('Ceramic mug'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect((await refreshed).name, 'Ceramic mug');
    expect(api.productCalls, 3);
  });

  testWidgets(
    'data_retry: none: error.dart at once, no retries, even when the app '
    'uses Riverpod default retry',
    (tester) async {
      final api = CountingApi();
      // `retry: null` is Riverpod's own policy (10 retries with backoff).
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/products/13'),
        overrides: [apiProvider.overrideWithValue(api), fakeImages()],
        retry: null,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining("Couldn't load product #13"), findsOneWidget);
      expect(api.productCalls, 1);

      // Nothing is scheduled behind the scenes: an armed retry timer would
      // also fail this test when it ends.
      await tester.pump(const Duration(minutes: 2));
      expect(find.textContaining("Couldn't load product #13"), findsOneWidget);
      expect(api.productCalls, 1);
    },
  );

  testWidgets(
    "error.dart's retry invalidates, and its error stays up meanwhile",
    (tester) async {
      final api = CountingApi();
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/products/13'),
        overrides: [apiProvider.overrideWithValue(api), fakeImages()],
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.productCalls, 2);
      expect(find.byType(ProductsLoading), findsNothing);
      expect(find.textContaining("Couldn't load product #13"), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Flaky grinder (fails once)'), findsOneWidget);
      expect(find.textContaining("Couldn't load"), findsNothing);
    },
  );
}
