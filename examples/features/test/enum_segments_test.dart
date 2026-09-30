import 'package:features/app.g.dart';
import 'package:features/app/shop/\$category/data.dart' as shop_data;
import 'package:features/app/shop/\$category/page.dart' show Sort;
import 'package:features/models/category.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Future<void> boot(WidgetTester tester, String location) async {
  await tester.pumpWidget(
    ProviderScope(
      // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
      // nesting both gives Material pages and error screens on either.
      child: MaterialApp(
        home: mui.MaterialApp.router(
          routerConfig: AppRoutes.router(initialLocation: location),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Enum segments (`shop/$category/`: `Category category`), a query parameter that is an
/// enum (`Sort? sort`) and a catch-all that is a list of them (`browse/$$categories/`).
void main() {
  setUp(() => shop_data.shopFetches = 0);

  group('an enum segment', () {
    testWidgets('is the value whose name the segment spells', (tester) async {
      await boot(tester, '/shop/shoes');
      expect(find.text('Shop shoes: sneaker, boot'), findsOneWidget);
      await boot(tester, '/shop/hats');
      expect(find.text('Shop hats: cap, beret'), findsOneWidget);
    });

    testWidgets('an unknown name is not found, like a bad int', (tester) async {
      await boot(tester, '/shop/socks');
      expect(find.text('Nothing at /shop/socks'), findsOneWidget);
      expect(shop_data.shopFetches, 0);
    });

    testWidgets(
      'the name is matched in any case here (case_sensitive: false)',
      (tester) async {
        await boot(tester, '/shop/HATS');
        expect(find.text('Shop hats: cap, beret'), findsOneWidget);
        await boot(tester, '/Shop/Shoes');
        expect(find.text('Shop shoes: sneaker, boot'), findsOneWidget);
      },
    );

    testWidgets(
      'keys data.dart: one run per value, the provider the route has',
      (tester) async {
        final container = await pumpRouter(
          tester,
          AppRoutes.router(initialLocation: '/shop/hats'),
        );
        expect(find.text('Shop hats: cap, beret'), findsOneWidget);
        expect(shop_data.shopFetches, 1);
        final hats = CategoryShopRoute.data(Category.hats);
        expect(container.read(hats).value, ['cap', 'beret']);
        expect(shop_data.shopFetches, 1);
        // Another value is another provider, which nothing has asked for yet.
        expect(
          container.exists(CategoryShopRoute.data(Category.shoes)),
          isFalse,
        );
      },
    );

    testWidgets('the typed route has the enum, and writes its name', (
      tester,
    ) async {
      const route = CategoryShopRoute(category: Category.hats);
      expect(route.location, '/shop/hats');
      await boot(tester, '/shop/shoes');
      route.go(tester.element(find.text('Shop shoes: sneaker, boot')));
      await tester.pumpAndSettle();
      expect(find.text('Shop hats: cap, beret'), findsOneWidget);
    });
  });

  group('an enum query parameter', () {
    testWidgets('is the value it names, and null when it names none', (
      tester,
    ) async {
      await boot(tester, '/shop/hats?sort=name');
      expect(find.text('Shop hats: beret, cap'), findsOneWidget);
      expect(find.text('sorted by name'), findsOneWidget);
      await boot(tester, '/shop/hats?sort=price');
      expect(find.text('sorted by price'), findsOneWidget);
      await boot(tester, '/shop/hats?sort=size');
      expect(find.text('sorted by default'), findsOneWidget);
      await boot(tester, '/shop/hats');
      expect(find.text('sorted by default'), findsOneWidget);
    });

    testWidgets('the typed route writes it by name', (tester) async {
      const route = CategoryShopRoute(
        category: Category.shoes,
        sort: Sort.name,
      );
      expect(route.location, '/shop/shoes?sort=name');
      expect(
        const CategoryShopRoute(category: Category.shoes).location,
        '/shop/shoes',
      );
      await boot(tester, '/shop/hats');
      route.go(tester.element(find.text('Shop hats: cap, beret')));
      await tester.pumpAndSettle();
      expect(find.text('Shop shoes: boot, sneaker'), findsOneWidget);
      expect(find.text('sorted by name'), findsOneWidget);
    });
  });

  group('a List of an enum as a catch-all', () {
    testWidgets('reads every part by name', (tester) async {
      await boot(tester, '/browse/shoes/hats/shoes');
      expect(
        find.text('Browse shoes + hats + shoes (2 different)'),
        findsOneWidget,
      );
      await boot(tester, '/browse/HATS');
      expect(find.text('Browse hats (1 different)'), findsOneWidget);
    });

    testWidgets('one part that names no value is not found', (tester) async {
      await boot(tester, '/browse/shoes/socks');
      expect(find.text('Nothing at /browse/shoes/socks'), findsOneWidget);
    });

    testWidgets('the typed route writes each part by name', (tester) async {
      const route = BrowseRoute(categories: [Category.hats, Category.shoes]);
      expect(route.location, '/browse/hats/shoes');
      await boot(tester, route.location);
      expect(find.text('Browse hats + shoes (2 different)'), findsOneWidget);
    });
  });
}
