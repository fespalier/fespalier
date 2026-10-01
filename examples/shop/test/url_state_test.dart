// The URL as state: the products list keeps its sort and page in the query, and its
// controls change one of them with `ProductsRoute.of(context).copyWith(...)`.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:shop/app/products/page.dart';

/// What the app told the platform (the browser's history) about its location.
typedef HistoryUpdate = ({String uri, bool replace});

/// Boots the generated router at [location], records what it reports to the
/// platform's history in [history], and waits for the products to load.
Future<void> boot(
  WidgetTester tester,
  String location,
  List<HistoryUpdate> history,
) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.navigation,
    (call) async {
      if (call.method == 'routeInformationUpdated') {
        final args = call.arguments as Map<Object?, Object?>;
        history.add(
            (uri: args['uri']! as String, replace: args['replace']! as bool));
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.navigation, null),
  );
  await pumpRouter(tester, AppRoutes.router(initialLocation: location),
      settle: false);
  await tester.pump(const Duration(seconds: 1)); // FakeApi's 700 ms
  await tester.pump();
}

/// The browser's back or forward button: the engine tells the app the location
/// of the history entry it moved to.
Future<void> browserGoesTo(WidgetTester tester, String location) async {
  const codec = JSONMethodCodec();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    codec.encodeMethodCall(
      MethodCall('pushRouteInformation', {'location': location}),
    ),
    (_) {},
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400)); // the page transition
}

/// The names of the products on screen, in order.
List<String> names(WidgetTester tester) => [
      for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
        (t.title! as Text).data!,
    ];

Future<void> tapAndPump(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400)); // the page transition
}

void main() {
  group('copyWith, as a value', () {
    test('leaves out what it is not given, and clears what it is given null',
        () {
      const route = ProductsRoute(sort: Sort.name, page: 2);
      expect(route.location, '/products?sort=name&page=2');
      expect(route.copyWith(page: 3).location, '/products?sort=name&page=3');
      expect(route.copyWith(sort: Sort.expensive).page, 2);
      // `null` is a value: it clears the parameter.
      expect(route.copyWith(page: null).location, '/products?sort=name');
      expect(route.copyWith(sort: null, page: null).location, '/products');
      // Nothing given, nothing changed.
      expect(route.copyWith().location, route.location);
    });

    test('a segment is changed the same way, and cannot be null', () {
      const route = ProductRoute(id: 1);
      expect(route.copyWith(id: 2).location, '/products/2');
      expect(route.copyWith().location, '/products/1');
    });

    test('the signature has the fields types, not dynamic', () {
      // If copyWith widened its parameters this would not compile as typed.
      final ProductsRoute Function({Sort? sort, int? page}) copy =
          const ProductsRoute().copyWith;
      expect(copy(page: 4).page, 4);
    });
  });

  group('of and maybeOf', () {
    testWidgets('read the typed route from the URL', (tester) async {
      final history = <HistoryUpdate>[];
      await boot(tester, '/products?sort=expensive&page=2', history);
      final context = tester.element(find.byType(ListView));
      final route = ProductsRoute.of(context);
      expect(route.sort, Sort.expensive);
      expect(route.page, 2);
      expect(ProductsRoute.maybeOf(context)?.page, 2);
    });

    testWidgets('a value that does not parse is null, as for the page', (
      tester,
    ) async {
      await boot(tester, '/products?sort=cheap&page=x', []);
      final route = ProductsRoute.of(tester.element(find.byType(ListView)));
      expect(route.sort, isNull);
      expect(route.page, isNull);
    });

    testWidgets('of throws on another route, maybeOf is null', (tester) async {
      await boot(tester, '/products', []);
      final context = tester.element(find.byType(ListView));
      expect(CartRoute.maybeOf(context), isNull);
      expect(
        () => CartRoute.of(context),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('CartRoute.of(context)'), contains('/products')),
          ),
        ),
      );
    });

    testWidgets('outside a route, of throws go_router\'s error',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));
      expect(ProductsRoute.maybeOf(context), isNull);
      expect(() => ProductsRoute.of(context), throwsA(isA<GoError>()));
    });

    testWidgets('in the layout, above the page, they read the whole location', (
      tester,
    ) async {
      await boot(tester, '/products?page=2', []);
      final layout = tester.element(find.byType(AppBar));
      expect(ProductsRoute.of(layout).page, 2);
      expect(CartRoute.maybeOf(layout), isNull);
    });
  });

  group('the products list', () {
    testWidgets('a link restores the view it was copied from', (tester) async {
      await boot(tester, '/products?sort=expensive&page=2', []);
      expect(names(tester), ['Coffee beans, 500 g']);
      expect(find.text('Page 2 of 2'), findsOneWidget);
    });

    testWidgets('Next goes to the next page: a history entry, and the URL', (
      tester,
    ) async {
      final history = <HistoryUpdate>[];
      await boot(tester, '/products', history);
      expect(names(tester), [
        'Coffee beans, 500 g',
        'Ceramic mug',
        'Pour-over kettle',
      ]);
      history.clear();

      await tapAndPump(tester, find.text('Next'));
      expect(currentLocation(tester), '/products?page=2');
      expect(names(tester), ['Flaky grinder (fails once)']);
      expect(history, [(uri: '/products?page=2', replace: false)]);
    });

    testWidgets('Previous to page 1 leaves ?page= out', (tester) async {
      await boot(tester, '/products?sort=name&page=2', []);
      await tapAndPump(tester, find.text('Previous'));
      expect(currentLocation(tester), '/products?sort=name');
    });

    testWidgets('a sort starts again at page 1', (
      tester,
    ) async {
      final history = <HistoryUpdate>[];
      await boot(tester, '/products?page=2', history);
      history.clear();

      await tapAndPump(tester, find.text('Sort by expensive'));
      // `copyWith(sort: ..., page: null)`: the page is gone from the URL.
      expect(currentLocation(tester), '/products?sort=expensive');
      expect(names(tester), [
        'Flaky grinder (fails once)',
        'Pour-over kettle',
        'Ceramic mug',
      ]);
      expect(history, [(uri: '/products?sort=expensive', replace: false)]);

      // Choosing it again clears the sort: `copyWith(sort: null, page: null)`.
      await tapAndPump(tester, find.text('Sort by expensive'));
      expect(currentLocation(tester), '/products');
    });

    testWidgets('back and forward restore each view', (tester) async {
      final history = <HistoryUpdate>[];
      await boot(tester, '/products', history);
      await tapAndPump(tester, find.text('Sort by name'));
      await tapAndPump(tester, find.text('Next'));
      expect(currentLocation(tester), '/products?sort=name&page=2');
      expect(names(tester), ['Pour-over kettle']);
      expect(find.text('Page 2 of 2'), findsOneWidget);
      // The first entry is the one the app started on; every change after it
      // was a new history entry.
      expect(history.map((h) => h.uri), [
        '/products',
        '/products?sort=name',
        '/products?sort=name&page=2',
      ]);
      expect(history.skip(1).where((h) => h.replace), isEmpty);

      // The browser's back button: the entry before.
      await browserGoesTo(tester, '/products?sort=name');
      expect(currentLocation(tester), '/products?sort=name');
      expect(names(tester), [
        'Ceramic mug',
        'Coffee beans, 500 g',
        'Flaky grinder (fails once)',
      ]);
      expect(find.text('Page 1 of 2'), findsOneWidget);

      await browserGoesTo(tester, '/products');
      expect(currentLocation(tester), '/products');
      expect(names(tester).first, 'Coffee beans, 500 g');
      expect(find.text('Sort by name'), findsOneWidget);

      // Forward again: the controls below the page read the new URL, so they
      // go on from where the browser put them.
      await browserGoesTo(tester, '/products?sort=name&page=2');
      expect(names(tester), ['Pour-over kettle']);
      await tapAndPump(tester, find.text('Previous'));
      expect(currentLocation(tester), '/products?sort=name');
    });

    testWidgets('replace shows the copy, and of reads it', (
      tester,
    ) async {
      await boot(tester, '/products', []);
      ProductsRoute.of(tester.element(find.byType(ListView)))
          .copyWith(sort: Sort.name)
          .replace(tester.element(find.byType(ListView)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(currentLocation(tester), '/products?sort=name');
      expect(names(tester).first, 'Ceramic mug');
      expect(
        ProductsRoute.of(tester.element(find.byType(ListView))).sort,
        Sort.name,
      );
    });

    testWidgets('a push is undone by pop', (tester) async {
      await boot(tester, '/products', []);
      final context = tester.element(find.byType(ListView));
      ProductsRoute.of(context).copyWith(sort: Sort.name).push<void>(context);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(currentLocation(tester), '/products?sort=name');

      GoRouter.of(tester.element(find.byType(ListView).last)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(currentLocation(tester), '/products');
      expect(names(tester).first, 'Coffee beans, 500 g');
    });

    testWidgets('the data is loaded once, however the view changes', (
      tester,
    ) async {
      final api = _CountingApi();
      final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/products'),
        container: container,
        settle: false,
      );
      await tester.pump(const Duration(seconds: 1));
      await tapAndPump(tester, find.text('Next'));
      await tapAndPump(tester, find.text('Sort by name'));
      expect(api.calls, 1);
    });
  });

  group('under a mount point', () {
    testWidgets('of reads the location without the prefix', (tester) async {
      addTearDown(() => AppRoutes.mount()); // restore base for other tests
      final router = GoRouter(
        initialLocation: '/shop/products?sort=name',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const Text('legacy home')),
          ...AppRoutes.mount(at: '/shop'),
        ],
      );
      await pumpRouter(tester, router, settle: false);
      await tester.pump(const Duration(seconds: 1));
      final context = tester.element(find.byType(ListView));
      final route = ProductsRoute.of(context);
      expect(route.sort, Sort.name);
      // And a copy goes to the same mounted location.
      expect(
          route.copyWith(page: 2).location, '/shop/products?sort=name&page=2');
      route.copyWith(page: 2).go(context);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(currentLocation(tester), '/shop/products?sort=name&page=2');
    });
  });
}

class _CountingApi extends FakeApi {
  var calls = 0;

  @override
  Future<List<Product>> products() {
    calls++;
    return super.products();
  }
}
