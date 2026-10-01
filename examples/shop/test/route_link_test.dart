// RouteLink on the product list, and the generated preload helpers.
import 'dart:ui' show SemanticsAction;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:shop/app/layout.dart';
import 'package:shop/app/products/loading.dart';

class CountingApi extends FakeApi {
  var productCalls = 0;

  @override
  Future<Product> product(int id) {
    productCalls++;
    return super.product(id);
  }
}

WidgetRef rootRef(WidgetTester tester) =>
    tester.element(find.byType(AppLayout)) as WidgetRef;

Future<(CountingApi, ProviderContainer)> boot(
  WidgetTester tester,
  String location,
) async {
  final api = CountingApi();
  final container = await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: location),
    overrides: [apiProvider.overrideWithValue(api)],
  );
  // data.dart is slow on purpose (a timer, not a frame): wait it out.
  await tester.pump(const Duration(seconds: 1));
  return (api, container);
}

void main() {
  group('the product list', () {
    testWidgets('a row is a link to its product, with its URL', (tester) async {
      final semantics = tester.ensureSemantics();
      await boot(tester, '/products');
      final data =
          tester.getSemantics(find.text('Ceramic mug')).getSemanticsData();
      expect(data.flagsCollection.isLink, isTrue);
      expect(data.linkUrl, Uri.parse('/products/2'));
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      semantics.dispose();
    });

    testWidgets('a click goes to the product', (tester) async {
      await boot(tester, '/products');
      await tester.tap(find.text('Pour-over kettle'));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/products/3');
      expect(find.text('€38.00'), findsOneWidget);
    });

    testWidgets('hovering a row loads its product before the click', (
      tester,
    ) async {
      final (api, container) = await boot(tester, '/products');
      expect(api.productCalls, 0);

      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      addTearDown(pointer.removePointer);
      await pointer.moveTo(tester.getCenter(find.text('Ceramic mug')));
      await tester.pump(const Duration(seconds: 1));
      expect(api.productCalls, 1);
      expect(container.read(ProductRoute.data(2)).value?.name, 'Ceramic mug');

      // The page is there at once, without loading again.
      await tester.tap(find.text('Ceramic mug'));
      await tester.pump();
      expect(currentLocation(tester), '/products/2');
      expect(find.byType(ProductsLoading), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      expect(api.productCalls, 1);
    });
  });

  group('preload', () {
    testWidgets('a route preloads its data and one handle closes it', (
      tester,
    ) async {
      final (api, container) = await boot(tester, '/');
      final handle = const ProductRoute(id: 2).preload(rootRef(tester));
      await tester.pump(const Duration(seconds: 1));
      expect(api.productCalls, 1);
      expect(container.exists(ProductRoute.data(2)), isTrue);
      expect(currentLocation(tester), '/');

      handle.close();
      await tester.pump();
      expect(container.exists(ProductRoute.data(2)), isFalse);
    });

    testWidgets('AppRoutes.preload does the same from a location', (
      tester,
    ) async {
      final (api, container) = await boot(tester, '/');
      final ref = rootRef(tester);
      final handle = AppRoutes.preload(ref, Uri.parse('/products/3'));
      await tester.pump(const Duration(seconds: 1));
      expect(api.productCalls, 1);
      expect(container.exists(ProductRoute.data(3)), isTrue);
      handle.close();
      await tester.pump();
      expect(container.exists(ProductRoute.data(3)), isFalse);

      // Nothing to warm: a route without data, a location no route fits, a
      // segment that doesn't parse.
      expect(AppRoutes.preload(ref, Uri.parse('/cart')).isClosed, isTrue);
      expect(AppRoutes.preload(ref, Uri.parse('/nope')).isClosed, isTrue);
      expect(AppRoutes.preload(ref, Uri.parse('/products/x')).isClosed, isTrue);
      expect(api.productCalls, 1);
    });

    testWidgets('it runs no guard and goes nowhere', (tester) async {
      await boot(tester, '/');
      // /checkout's guard.dart sends an empty cart to /cart.
      final handle = const CheckoutRoute().preload(rootRef(tester));
      await tester.pump();
      expect(handle.isClosed, isTrue);
      expect(currentLocation(tester), '/');
    });
  });
}
