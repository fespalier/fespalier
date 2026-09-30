// Localized paths: what the runtime does for `const paths = {'fr': 'produits'};`.
//
// A localized folder is one go_router route whose segment is a parameter that matches every
// spelling (`:_l0(products|produits|produkte)`), so these tests build the routes by hand, as
// `fsp gen` writes them, and check what go_router does with them.
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class ProductsRoute extends TypedLocation {
  const ProductsRoute();
  @override
  String get location => '/products';
  @override
  String locationFor(String? locale) =>
      '/${localizedSegment(locale, 'products', {'fr': 'produits', 'de': 'produkte'})}';
}

final class ProductRoute extends TypedLocation {
  const ProductRoute({required this.id});
  final int id;
  @override
  String get location => '/products/$id';
  @override
  String locationFor(String? locale) =>
      '/${localizedSegment(locale, 'products', {'fr': 'produits', 'de': 'produkte'})}/$id';
}

final class AboutRoute extends TypedLocation {
  const AboutRoute();
  @override
  String get location => '/about';
}

GoRouter buildRouter(
  String initial, {
  bool caseSensitive = true,
  void Function(GoRouterState)? seen,
}) {
  Widget page(String text, GoRouterState s) {
    seen?.call(s);
    return Text(text);
  }

  return GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/:_l0(products|produits|produkte)',
        caseSensitive: caseSensitive,
        builder: (context, s) => page('products', s),
        routes: [
          GoRoute(
            path: ':id',
            caseSensitive: caseSensitive,
            builder: (context, s) =>
                page('product ${s.pathParameters['id']}', s),
            routes: [
              GoRoute(
                path: ':_l2(reviews|avis)',
                caseSensitive: caseSensitive,
                builder: (context, s) =>
                    page('reviews of ${s.pathParameters['id']}', s),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/about',
        caseSensitive: caseSensitive,
        builder: (context, s) => page('about', s),
      ),
    ],
  );
}

Future<GoRouter> boot(WidgetTester tester, GoRouter router) async {
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('localizedSegment', () {
    const fr = {'fr': 'produits', 'de': 'produkte'};

    test('is the spelling for the locale', () {
      expect(localizedSegment('fr', 'products', fr), 'produits');
      expect(localizedSegment('de', 'products', fr), 'produkte');
    });

    test(
      'is the canonical one for no locale, an unknown one or an empty map',
      () {
        expect(localizedSegment(null, 'products', fr), 'products');
        expect(localizedSegment('', 'products', fr), 'products');
        expect(localizedSegment('es', 'products', fr), 'products');
        expect(localizedSegment('fr', 'products', const {}), 'products');
      },
    );

    test('a region falls back to its language, and an exact tag wins', () {
      expect(localizedSegment('fr-CA', 'products', fr), 'produits');
      expect(localizedSegment('fr_CA', 'products', fr), 'produits');
      expect(
        localizedSegment('fr-CA', 'products', {...fr, 'fr-CA': 'produits-ca'}),
        'produits-ca',
      );
      // The other way round does not hold: `fr` is not `fr-CA`.
      expect(
        localizedSegment('fr', 'products', const {'fr-CA': 'produits-ca'}),
        'products',
      );
    });

    test('tags compare without regard to case, and `_` is `-`', () {
      expect(localizedSegment('FR', 'products', fr), 'produits');
      expect(
        localizedSegment('pt-br', 'products', const {'pt-BR': 'produtos'}),
        'produtos',
      );
      expect(
        localizedSegment('pt_BR', 'products', const {'pt-BR': 'produtos'}),
        'produtos',
      );
      expect(sameLocale('zh_Hant', 'zh-hant'), isTrue);
      expect(sameLocale('fr', 'fr-CA'), isFalse);
    });
  });

  group('TypedLocation', () {
    test('locationFor is the location unless the route overrides it', () {
      const about = AboutRoute();
      expect(about.locationFor('fr'), '/about');
      expect(about.locationFor(null), '/about');
    });

    test('a localized route keeps location canonical', () {
      const product = ProductRoute(id: 2);
      expect(product.location, '/products/2');
      expect(product.locationFor('fr'), '/produits/2');
      expect(product.locationFor('de'), '/produkte/2');
      expect(product.locationFor('es'), '/products/2');
    });

    testWidgets('go, push and replace take the locale', (tester) async {
      final router = await boot(tester, buildRouter('/about'));
      final context = tester.element(find.text('about'));

      const ProductRoute(id: 2).go(context, locale: 'fr');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/produits/2');

      const ProductsRoute().push<void>(
        tester.element(find.text('product 2')),
        locale: 'de',
      );
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/produkte');

      const ProductRoute(
        id: 3,
      ).replace(tester.element(find.text('products')), locale: 'fr');
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/produits/3');

      // No locale: canonical.
      const ProductRoute(id: 4).go(tester.element(find.text('product 3')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/products/4');
    });
  });

  group('go_router with an alternation', () {
    testWidgets('every spelling reaches the same route and params', (
      tester,
    ) async {
      for (final path in ['/products/7', '/produits/7', '/produkte/7']) {
        await boot(tester, buildRouter(path));
        expect(find.text('product 7'), findsOneWidget, reason: path);
      }
      for (final path in ['/products', '/produits', '/produkte']) {
        await boot(tester, buildRouter(path));
        expect(find.text('products'), findsOneWidget, reason: path);
      }
    });

    testWidgets('a nested child resolves under every spelling, mixed or not', (
      tester,
    ) async {
      for (final path in [
        '/products/7/reviews',
        '/produits/7/avis',
        '/produkte/7/reviews',
        '/products/7/avis',
      ]) {
        await boot(tester, buildRouter(path));
        expect(find.text('reviews of 7'), findsOneWidget, reason: path);
      }
    });

    testWidgets('the parent is built beneath the child', (tester) async {
      final router = await boot(tester, buildRouter('/produits/7/avis'));
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('product 7'), findsOneWidget);
      expect(router.state.uri.path, '/produits/7');
    });

    testWidgets('the location is kept as requested, and matchedLocation spells '
        'the route as the URL did', (tester) async {
      late GoRouterState state;
      final router = await boot(
        tester,
        buildRouter('/produits/7', seen: (s) => state = s),
      );
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/produits/7',
      );
      expect(state.matchedLocation, '/produits/7');
      expect(state.pathParameters['id'], '7');
      // The parameter that carries the spelling is go_router's, named `_l<depth>`.
      expect(state.pathParameters['_l0'], 'produits');
      expect(state.fullPath, '/:_l0(products|produits|produkte)/:id');
    });

    testWidgets('one page key for every spelling', (tester) async {
      late GoRouterState state;
      await boot(tester, buildRouter('/products/7', seen: (s) => state = s));
      final canonical = state.pageKey;
      await boot(tester, buildRouter('/produits/7', seen: (s) => state = s));
      expect(state.pageKey, canonical);
    });

    testWidgets('case-insensitive routes match the spellings in any case', (
      tester,
    ) async {
      await boot(tester, buildRouter('/PRODUITS/7/Avis', caseSensitive: false));
      expect(find.text('reviews of 7'), findsOneWidget);
    });

    testWidgets('case-sensitive routes do not', (tester) async {
      await boot(tester, buildRouter('/Produits/7'));
      expect(find.text('product 7'), findsNothing);
    });

    testWidgets('a spelling nobody has is not found', (tester) async {
      await boot(tester, buildRouter('/prodotti/7'));
      expect(find.text('product 7'), findsNothing);
      await boot(tester, buildRouter('/produit/7'));
      expect(find.text('product 7'), findsNothing);
    });

    testWidgets('a spelling with a dot is matched literally', (tester) async {
      final router = GoRouter(
        initialLocation: '/v1.0',
        routes: [
          GoRoute(
            path: r'/:_l0(version|v1\.0)',
            builder: (context, s) => const Text('found'),
          ),
        ],
      );
      await boot(tester, router);
      expect(find.text('found'), findsOneWidget);
      final other = GoRouter(
        initialLocation: '/v1x0',
        routes: [
          GoRoute(
            path: r'/:_l0(version|v1\.0)',
            builder: (context, s) => const Text('found'),
          ),
        ],
      );
      await boot(tester, other);
      expect(find.text('found'), findsNothing);
    });
  });

  group('a tab whose first route is localized', () {
    // go_router opens a tab on its first route and asserts that it has no path
    // parameter, which a localized segment is: `fsp gen` writes an initialLocation.
    GoRouter tabs(String initial, {bool initialLocation = true}) => GoRouter(
      initialLocation: initial,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => Column(
            children: [
              Expanded(child: shell),
              TextButton(
                onPressed: () => shell.goBranch(1),
                child: const Text('second'),
              ),
              TextButton(
                onPressed: () => shell.goBranch(0),
                child: const Text('first'),
              ),
            ],
          ),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/', builder: (c, s) => const Text('home')),
              ],
            ),
            StatefulShellBranch(
              initialLocation: initialLocation ? '/search' : null,
              routes: [
                GoRoute(
                  path: '/:_l0(search|recherche)',
                  builder: (c, s) => const Text('search'),
                ),
              ],
            ),
          ],
        ),
      ],
    );

    test('without one, go_router refuses the tab (why fsp writes it)', () {
      expect(
        () => tabs('/', initialLocation: false),
        throwsA(
          isA<AssertionError>().having(
            (e) => e.message,
            'message',
            contains('cannot be a parameterized route'),
          ),
        ),
      );
    });

    testWidgets('opens on the canonical initialLocation', (tester) async {
      final router = await boot(tester, tabs('/'));
      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(find.text('search'), findsOneWidget);
      expect(router.state.uri.path, '/search');
    });

    testWidgets('a deep link through the spelling opens the tab', (
      tester,
    ) async {
      final router = await boot(tester, tabs('/recherche'));
      expect(find.text('search'), findsOneWidget);
      expect(router.state.uri.path, '/recherche');
      await tester.tap(find.text('first'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('second'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/recherche');
    });
  });

  group('matchRoutes', () {
    UrlMatch build(GoRouterState s) => UrlMatch(s.uri, const AboutRoute(), {
      for (final e in s.pathParameters.entries) e.key: e.value,
    }, const []);
    final matchers = [
      RouteMatcher(['about'], build),
      RouteMatcher(['products|produits|produkte'], build),
      RouteMatcher(['products|produits|produkte', ':id'], build),
      RouteMatcher([
        'products|produits|produkte',
        ':id',
        'reviews|avis',
      ], build),
      RouteMatcher(['docs|dokumente', '*rest'], build),
    ];

    Map<String, Object?>? at(
      String location, {
      bool caseSensitive = true,
      List<RouteMatcher>? routes,
    }) => matchRoutes(
      Uri.parse(location),
      '/',
      routes ?? matchers,
      caseSensitive: caseSensitive,
    )?.params;

    test('a part with `|` matches any of its spellings', () {
      expect(at('/products'), isEmpty);
      expect(at('/produits'), isEmpty);
      expect(at('/produkte'), isEmpty);
      expect(at('/produits/3'), {'id': '3'});
      expect(at('/produkte/3/avis'), {'id': '3'});
      expect(at('/products/3/avis'), {'id': '3'});
      expect(at('/prod'), isNull);
      expect(at('/produit/3'), isNull);
    });

    test('a spelling is matched whole, not by prefix', () {
      expect(at('/productsx'), isNull);
      expect(at('/produits/3/avisx'), isNull);
    });

    test('case is the route\'s own setting', () {
      expect(at('/Produits/3'), isNull);
      final insensitive = [
        RouteMatcher(['products|produits', ':id'], build, caseSensitive: false),
      ];
      expect(at('/PRODUITS/3', routes: insensitive), {'id': '3'});
      expect(at('/Products/3', routes: insensitive), {'id': '3'});
    });

    test('a catch-all below a localized folder reads its parts', () {
      final m = matchRoutes(Uri.parse('/dokumente/a/b%20c'), '/', [
        RouteMatcher(['docs|dokumente', '*rest'], (s) {
          final rest = Segment.asRest(s, 'rest');
          return UrlMatch(s.uri, const AboutRoute(), {'rest': rest}, const []);
        }),
      ]);
      expect(m!.params['rest'], ['a', 'b c']);
    });

    test('a mount point and a localized folder together', () {
      final m = matchRoutes(Uri.parse('/shop/produits/3'), '/shop', matchers);
      expect(m!.params, {'id': '3'});
    });

    test('partMatches', () {
      expect(partMatches('a|b', 'b', true), isTrue);
      expect(partMatches('a|b', 'c', true), isFalse);
      expect(partMatches('a', 'a', true), isTrue);
      expect(partMatches('a|B', 'b', false), isTrue);
      expect(partMatches('a|B', 'b', true), isFalse);
    });
  });

  group('nearestNotFound', () {
    Widget scoped(Uri uri, {bool caseSensitive = true}) =>
        nearestNotFound(uri, '/', [
          (
            ['products|produits', ':id', 'reviews|avis'],
            (uri) => Text('reviews ${uri.path}'),
            caseSensitive: caseSensitive,
          ),
          (
            ['products|produits'],
            (uri) => Text('products ${uri.path}'),
            caseSensitive: caseSensitive,
          ),
        ], (uri) => Text('root ${uri.path}'));

    String shown(Widget w) => (w as Text).data!;

    test('covers every spelling of its prefix', () {
      expect(shown(scoped(Uri.parse('/products/x'))), 'products /products/x');
      expect(shown(scoped(Uri.parse('/produits/x'))), 'products /produits/x');
      expect(
        shown(scoped(Uri.parse('/produits/3/avis/x'))),
        'reviews /produits/3/avis/x',
      );
      expect(
        shown(scoped(Uri.parse('/products/3/avis/x'))),
        'reviews /products/3/avis/x',
      );
    });

    test('elsewhere the root one', () {
      expect(shown(scoped(Uri.parse('/produit/x'))), 'root /produit/x');
      expect(shown(scoped(Uri.parse('/other'))), 'root /other');
    });

    test('case is the scope\'s own setting', () {
      expect(shown(scoped(Uri.parse('/Produits/x'))), 'root /Produits/x');
      expect(
        shown(scoped(Uri.parse('/Produits/x'), caseSensitive: false)),
        'products /Produits/x',
      );
    });
  });

  group('RouteInfo', () {
    const info = RouteInfo<Object?>(
      type: ProductRoute,
      path: '/products/:id',
      paths: {'fr': '/produits/:id', 'pt-BR': '/produtos/:id'},
      folder: r'products/$id',
    );

    test('has paths, empty by default', () {
      expect(info.paths, {'fr': '/produits/:id', 'pt-BR': '/produtos/:id'});
      const plain = RouteInfo<Object?>(type: String, path: '/', folder: '');
      expect(plain.paths, isEmpty);
      expect(plain.pathFor('fr'), '/');
    });

    test(
      'pathFor is the locale\'s path, the language\'s, or the canonical',
      () {
        expect(info.pathFor('fr'), '/produits/:id');
        expect(info.pathFor('fr-CA'), '/produits/:id');
        expect(info.pathFor('pt_br'), '/produtos/:id');
        expect(info.pathFor('pt'), '/products/:id');
        expect(info.pathFor('de'), '/products/:id');
        expect(info.pathFor(null), '/products/:id');
      },
    );

    testWidgets('routeTemplate is the canonical path at every spelling', (
      tester,
    ) async {
      late GoRouterState state;
      Future<void> at(String location) async {
        final router = GoRouter(
          initialLocation: location,
          routes: [
            GoRoute(
              path: '/shop/:_l1(products|produits)/:id/:_l3(v1\\.0|avis)',
              builder: (context, s) {
                state = s;
                return const SizedBox();
              },
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
      }

      await at('/shop/produits/7/avis');
      expect(routeTemplate(state), '/shop/products/:id/v1.0');
      expect(routeTemplate(state, '/shop'), '/products/:id/v1.0');
      await at('/shop/products/7/v1.0');
      expect(routeTemplate(state), '/shop/products/:id/v1.0');
    });

    testWidgets('routeTemplate keeps a catch-all next to a localized folder', (
      tester,
    ) async {
      late GoRouterState state;
      final router = GoRouter(
        initialLocation: '/dokumente/a/b',
        routes: [
          GoRoute(
            path: '/:_l0(docs|dokumente)/:rest(.+)',
            builder: (context, s) {
              state = s;
              return const SizedBox();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(routeTemplate(state), '/docs/*rest');
      expect(Segment.asRest(state, 'rest'), ['a', 'b']);
    });
  });
}
