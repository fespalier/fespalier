// AppRoutes.match / dataAt: from a location to the route's data providers, built from
// the same parsers the routes use, without running a guard or building a widget; and the
// typed handle of a section (reports/, keyed by a query parameter; teams/$teamId/).
import 'package:features/app.g.dart';
import 'package:features/app/reports/data.dart' as report_data;
import 'package:features/app/shop/\$category/page.dart' show Sort;
import 'package:features/catalog.dart';
import 'package:features/models/category.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

Uri at(String location) => Uri.parse(location);

List<ProviderListenable<AsyncValue<Object?>>>? dataAt(String location) =>
    AppRoutes.dataAt(at(location));

void main() {
  setUp(() {
    productFetches = 0;
    report_data.reportFetches = 0;
  });

  group('dataAt', () {
    test('is the provider the typed route has', () {
      expect(dataAt('/catalog/42')!.single, ProductDetailRoute.data('42'));
      // A data.dart that selects a provider: the selected provider itself.
      expect(dataAt('/catalog/42')!.single, productProvider('42'));
      // No key: the provider as it is.
      expect(dataAt('/catalog')!.single, same(featuredProvider));
      expect(dataAt('/counter')!.single, same(CounterRoute.data));
    });

    test(
      'a function data.dart: the generated provider, keyed by the segments',
      () {
        expect(
          dataAt('/shops/acme/items/7')!.single,
          ItemRoute.data((shop: 'acme', id: 7)),
        );
        expect(
          dataAt('/shops/acme/items/7')!.single,
          isNot(ItemRoute.data((shop: 'acme', id: 8))),
        );
      },
    );

    test('a segment that does not parse is null, like not_found.dart', () {
      expect(dataAt('/shops/acme/items/seven'), isNull);
      expect(AppRoutes.match(at('/shops/acme/items/seven')), isNull);
    });

    test('nothing at the location is null; a route without data is empty', () {
      expect(dataAt('/no/such/path'), isNull);
      expect(dataAt('/notes/3'), isEmpty);
      expect(dataAt('/'), isEmpty);
      // An optional catch-all also matches without its part.
      expect(dataAt('/files'), isEmpty);
      expect(dataAt('/files/a/b'), isEmpty);
      // A required one doesn't: /wiki is `/:slug`, as it is for the router.
      expect(AppRoutes.match(at('/wiki'))!.info.path, '/:slug');
    });

    test('query-keyed data is keyed by the query of the location', () {
      expect(
        dataAt('/search?q=ap&page=2&tags=red&tags=sweet')!.single,
        SearchRoute.data((q: 'ap', page: 2, tags: QueryList(['red', 'sweet']))),
      );
      expect(
        dataAt('/search?q=ap')!.single,
        SearchRoute.data((q: 'ap', page: null, tags: QueryList(<String>[]))),
      );
      expect(
        dataAt('/search?q=ap')!.single,
        isNot(dataAt('/search?q=b')!.single),
      );
      // The same query in another order is the same key.
      expect(
        dataAt('/search?q=a&tags=x&tags=y')!.single,
        dataAt('/search?tags=x&tags=y&q=a')!.single,
      );
      // A query parameter that is not a number is left out, as the page sees it.
      expect(
        dataAt('/catalog/1/reviews?page=x')!.single,
        ReviewsRoute.data((productId: '1', page: null)),
      );
      expect(
        dataAt('/catalog/1/reviews?page=3')!.single,
        ReviewsRoute.data((productId: '1', page: 3)),
      );
    });

    test('a catch-all keys data by its path', () {
      expect(
        dataAt('/wiki/a/b%2Fc')!.single,
        WikiRoute.data(restKey(['a', 'b/c'])),
      );
      expect(dataAt('/wiki/a/b')!.single, isNot(dataAt('/wiki/a/c')!.single));
    });

    test(
      'section data comes first, outermost first, then the route\'s own',
      () {
        final all = dataAt('/teams/acme/members/7')!;
        expect(all, hasLength(2));
        expect(all[0], TeamsTeamIdSection.data('acme'));
        expect(all[1], MemberRoute.data(7));
        // A route with no data.dart of its own still has its section's.
        expect(
          dataAt('/teams/acme/settings')!.single,
          TeamsTeamIdSection.data('acme'),
        );
      },
    );

    test('a section keyed by a query parameter, on every page below it', () {
      expect(
        dataAt('/reports/monthly?period=2026-01')!.single,
        ReportsSection.data('2026-01'),
      );
      expect(
        dataAt('/reports/yearly?period=2026-01')!.single,
        ReportsSection.data('2026-01'),
      );
      expect(dataAt('/reports/yearly')!.single, ReportsSection.data(null));
      // The typed route writes the query it is keyed by.
      expect(
        const MonthlyReportRoute(period: '2026-01').location,
        '/reports/monthly?period=2026-01',
      );
    });

    test('paths match by case here (case_sensitive: false)', () {
      expect(dataAt('/CATALOG/42')!.single, ProductDetailRoute.data('42'));
    });

    test('a typed catch-all parses each part; one that fails is no match', () {
      expect(
        dataAt('/compare/1/2/3')!.single,
        CompareRoute.data(restKey([1, 2, 3])),
      );
      expect(AppRoutes.match(at('/compare/1/2/3'))!.params, {
        'ids': [1, 2, 3],
      });
      expect(dataAt('/compare/1/x/3'), isNull);
      expect(AppRoutes.match(at('/compare/1/x')), isNull);
    });

    test('an enum segment is read by name; an unknown name is no match', () {
      expect(
        dataAt('/shop/hats')!.single,
        CategoryShopRoute.data(Category.hats),
      );
      expect(
        dataAt('/shop/hats')!.single,
        isNot(CategoryShopRoute.data(Category.shoes)),
      );
      // Paths match by case here, and so do the names.
      expect(
        dataAt('/SHOP/Shoes?sort=price')!.single,
        CategoryShopRoute.data(Category.shoes),
      );
      expect(dataAt('/shop/socks'), isNull);
      expect(AppRoutes.match(at('/shop/socks')), isNull);
      expect(AppRoutes.match(at('/shop/hats'))!.info.path, '/shop/:category');
    });

    test('an enum catch-all parses each part and keys data by its path', () {
      expect(
        dataAt('/browse/shoes/hats')!.single,
        BrowseRoute.data(restKey([Category.shoes, Category.hats])),
      );
      expect(
        dataAt('/browse/shoes/hats')!.single,
        isNot(dataAt('/browse/hats/shoes')!.single),
      );
      expect(AppRoutes.match(at('/browse/shoes/hats'))!.params, {
        'categories': [Category.shoes, Category.hats],
      });
      expect(dataAt('/browse/shoes/socks'), isNull);
      // A required catch-all needs a part: /browse is the app's `/:slug`.
      expect(AppRoutes.match(at('/browse'))!.info.path, '/:slug');
    });

    test('each route matches by its own case setting (route.dart)', () {
      // pubspec.yaml: any case. files/ has a route.dart that says exactly.
      expect(AppRoutes.match(at('/DOCS/a'))!.info.path, '/docs/*rest');
      expect(AppRoutes.match(at('/files/a'))!.info.path, '/files/*path?');
      expect(AppRoutes.match(at('/Files/a')), isNull);
      // /FILES isn't the exact-case files/ route: it is the app's `/:slug`.
      expect(AppRoutes.match(at('/FILES'))!.info.path, '/:slug');
      // A folder that is matched by case leaves the rest of the app alone.
      expect(dataAt('/CATALOG/42')!.single, ProductDetailRoute.data('42'));
      expect(dataAt('/Compare/1/2'), isNotNull);
    });

    test('the mount point is taken off', () {
      addTearDown(AppRoutes.mount);
      AppRoutes.mount(at: '/app');
      expect(dataAt('/app/catalog/42')!.single, ProductDetailRoute.data('42'));
      expect(dataAt('/catalog/42'), isNull);
    });

    test('no guard runs and no widget is built', () {
      // /admin is behind a guard; matching it says what it is, and nothing redirects.
      final m = AppRoutes.match(at('/admin'))!;
      expect(m.route, isA<AdminRoute>());
      expect(productFetches, 0);
    });
  });

  group('match', () {
    test('has the info, the parsed parameters and the data', () {
      final m = AppRoutes.match(at('/shops/acme/items/7?ignored=1'))!;
      expect(m.info, AppManifest.byType[ItemRoute]);
      expect(m.info.path, '/shops/:shop/items/:id');
      expect(m.params, {'shop': 'acme', 'id': 7});
      expect(m.route, isA<ItemRoute>());
      expect(m.route.location, '/shops/acme/items/7');
      expect(m.data.single, ItemRoute.data((shop: 'acme', id: 7)));
      expect(m.uri, at('/shops/acme/items/7?ignored=1'));
    });

    test('an enum segment and query parameter are the values they name', () {
      final m = AppRoutes.match(at('/shop/hats?sort=name'))!;
      expect(m.params, {'category': Category.hats, 'sort': Sort.name});
      expect(m.route, isA<CategoryShopRoute>());
      expect(m.route.location, '/shop/hats?sort=name');
      expect(m.data.single, CategoryShopRoute.data(Category.hats));
      // A query value that names no value is left out, as the page sees it.
      expect(AppRoutes.match(at('/shop/hats?sort=size'))!.params, {
        'category': Category.hats,
        'sort': null,
      });
    });

    test('lists the query parameters, absent ones as null', () {
      final m = AppRoutes.match(at('/search?page=2'))!;
      expect(m.params, {'q': null, 'page': 2, 'tags': <String>[]});
    });

    test('a catch-all is its parts, decoded on their own', () {
      final m = AppRoutes.match(at('/docs/a/b%2Fc/d'))!;
      expect(m.info.path, '/docs/*rest');
      expect(m.params, {
        'rest': ['a', 'b/c', 'd'],
      });
      expect(AppRoutes.match(at('/files'))!.params, {'path': <String>[]});
    });

    test('a static route wins over a dynamic one, like the router', () {
      expect(AppRoutes.match(at('/docs/new'))!.info.path, '/docs/new');
      expect(AppRoutes.match(at('/photos/sort'))!.info.path, '/photos/sort');
      expect(AppRoutes.match(at('/photos/9'))!.info.path, '/photos/:id');
    });

    test('present.dart and root-navigator routes match like any other', () {
      final share = AppRoutes.match(at('/photos/share'))!;
      expect(share.route, isA<ShareSheetRoute>());
      expect(share.info.presentation, RoutePresentation.custom);
      final terms = AppRoutes.match(at('/photos/share/terms'))!;
      expect(terms.info.presentation, RoutePresentation.root);
      expect(terms.data, isEmpty);
    });

    test('every route of the manifest matches its own typed location', () {
      final routes = <TypedLocation>[
        const HomeRoute(),
        const NoteRoute(id: 3),
        const ItemRoute(shop: 'a', id: 2),
        DocsRoute(rest: ['x', 'y']),
        const SearchRoute(q: 'z'),
        const CategoryShopRoute(category: Category.hats, sort: Sort.name),
        const BrowseRoute(categories: [Category.shoes, Category.hats]),
      ];
      for (final r in routes) {
        final m = AppRoutes.match(at(r.location))!;
        expect(m.route.runtimeType, r.runtimeType, reason: r.location);
        expect(m.route.location, r.location);
        expect(m.info, AppManifest.byType[r.runtimeType]);
      }
    });
  });

  group('prefetch', () {
    testWidgets('keeps the warm provider until the handle is closed', (
      tester,
    ) async {
      final container = await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/catalog'),
      );
      final ref =
          tester.element(find.byType(DataView<List<String>>)) as WidgetRef;

      final handle = const ProductDetailRoute(productId: '2').prefetch(ref);
      await tester.pump(const Duration(milliseconds: 50));
      expect(productFetches, 1);

      // Long after the old default of 30 s, with nothing watching it: still warm.
      await tester.pump(const Duration(minutes: 5));
      expect(container.exists(productProvider('2')), isTrue);
      expect(productFetches, 1);

      // The page it warmed finds it loaded.
      const ProductDetailRoute(productId: '2')
          .go(tester.element(find.byType(DataView<List<String>>)));
      await tester.pumpAndSettle();
      expect(find.text('Product 2'), findsOneWidget);
      expect(productFetches, 1);

      handle.close();
      expect(handle.isClosed, isTrue);
    });

    testWidgets(
        'from a location: dataAt feeds prefetchAll, one handle closes '
        'them all', (tester) async {
      final container = await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/catalog'),
      );
      final ref =
          tester.element(find.byType(DataView<List<String>>)) as WidgetRef;
      final handle = ref.prefetchAll(dataAt('/catalog/9')!);
      await tester.pump(const Duration(milliseconds: 50));
      expect(container.read(productProvider('9')).value?.name, 'Product 9');
      await tester.pump(const Duration(minutes: 1));
      expect(container.exists(productProvider('9')), isTrue);

      handle.close();
      await tester.pump();
      expect(container.exists(productProvider('9')), isFalse);
    });
  });

  group('a section\'s typed handle', () {
    testWidgets(
      'watches, reads, refreshes and prefetches what the section loads',
      (tester) async {
        final container = await pumpRouter(
          tester,
          AppRoutes.router(initialLocation: '/reports/monthly?period=2026-01'),
        );
        expect(find.text('Reports: Report 2026-01'), findsOneWidget);
        expect(find.text('Monthly: Report 2026-01'), findsOneWidget);
        // The layout and the page read the one provider: one run.
        expect(report_data.reportFetches, 1);
        expect(
          container.read(ReportsSection.data('2026-01')).value,
          'Report 2026-01',
        );

        final ref =
            tester.element(find.byType(DataView<String>).first) as WidgetRef;
        expect(
          await ReportsSection.read(ref, period: '2026-01'),
          'Report 2026-01',
        );
        expect(report_data.reportFetches, 1);

        final refreshing = ReportsSection.refresh(ref, period: '2026-01');
        await tester.pump();
        await refreshing;
        expect(report_data.reportFetches, 2);

        // Another period is another provider.
        final handle = ReportsSection.prefetch(ref, period: '2026-02');
        await tester.pump();
        expect(report_data.reportFetches, 3);
        expect(container.exists(ReportsSection.data('2026-02')), isTrue);
        handle.close();
      },
    );

    testWidgets('navigating with the typed route changes the section\'s key', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/reports/monthly?period=a'),
      );
      expect(find.text('Monthly: Report a'), findsOneWidget);
      const MonthlyReportRoute(period: 'b')
          .go(tester.element(find.text('Monthly: Report a')));
      await tester.pumpAndSettle();
      expect(find.text('Reports: Report b'), findsOneWidget);
      expect(find.text('Monthly: Report b'), findsOneWidget);
    });
  });

  group('not_found.dart takes the segments above it as Strings', () {
    testWidgets('for an unknown path under it', (tester) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/teams/acme/members/7/deeper'),
      );
      expect(
        find.text('No member at /teams/acme/members/7/deeper'),
        findsOneWidget,
      );
      expect(find.text('Team: acme'), findsOneWidget);
    });

    testWidgets('for a segment that fails to parse', (tester) async {
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/teams/Acme%20Co/members/x'),
      );
      expect(
        find.text('No member at /teams/Acme%20Co/members/x'),
        findsOneWidget,
      );
      expect(find.text('Team: Acme Co'), findsOneWidget);
    });
  });
}
