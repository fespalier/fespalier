import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What go_router does with the paths the generated code hands it: catch-all
/// parameters (`:rest(.+)`), `caseSensitive`, trailing slashes and `extra`.
void main() {
  int? seen;

  GoRouter router(String at, {bool caseSensitive = true}) => GoRouter(
    initialLocation: at,
    routes: [
      GoRoute(
        path: '/',
        caseSensitive: caseSensitive,
        builder: (context, state) => const Text('home'),
      ),
      GoRoute(
        path: '/docs/new',
        caseSensitive: caseSensitive,
        builder: (context, state) => const Text('new doc'),
      ),
      GoRoute(
        path: '/docs/:rest(.+)',
        caseSensitive: caseSensitive,
        builder: (context, state) =>
            Text('docs ${Segment.asRest(state, 'rest')}'),
      ),
      GoRoute(
        path: '/products',
        caseSensitive: caseSensitive,
        builder: (context, state) => Text('products ${state.uri.query}'),
      ),
      GoRoute(
        path: '/item',
        caseSensitive: caseSensitive,
        builder: (context, state) => Text('item ${extraOf<int>(state)}'),
      ),
      GoRoute(
        path: '/seen',
        redirect: (context, state) {
          // What a guard, a layout or a redirect reads: never an assertion.
          seen = extraOrNull<int>(state);
          return null;
        },
        builder: (context, state) => Text('seen $seen'),
      ),
    ],
  );

  Future<void> open(
    WidgetTester tester,
    String at, {
    bool caseSensitive = true,
  }) async {
    await pumpRouter(tester, router(at, caseSensitive: caseSensitive));
  }

  group('catch-all', () {
    testWidgets('matches one or more segments, static routes first', (
      tester,
    ) async {
      await open(tester, '/docs/a');
      expect(find.text('docs [a]'), findsOneWidget);
      await open(tester, '/docs/a/b/c');
      expect(find.text('docs [a, b, c]'), findsOneWidget);
      await open(tester, '/docs/new');
      expect(find.text('new doc'), findsOneWidget);
      await open(tester, '/docs/new/x');
      expect(find.text('docs [new, x]'), findsOneWidget);
    });

    testWidgets('needs at least one segment', (tester) async {
      await open(tester, '/docs');
      expect(
        find.textContaining('no routes for location: /docs'),
        findsOneWidget,
      );
    });

    testWidgets('decodes each part on its own', (tester) async {
      await open(tester, '/docs/a%2Fb/c%20d/%C3%A9');
      expect(find.text('docs [a/b, c d, é]'), findsOneWidget);
    });

    testWidgets('a trailing slash and a query leave no empty part', (
      tester,
    ) async {
      await open(tester, '/docs/a/b/?x=1');
      expect(find.text('docs [a, b]'), findsOneWidget);
    });

    test('restPath, restKey and restParts encode and decode', () {
      expect(restPath(['a', 'b c', 'd/e']), '/a/b%20c/d%2Fe');
      expect(restPath(const []), '');
      expect(restKey(['a', 'b c', 'd/e']), 'a/b%20c/d%2Fe');
      expect(restParts('a/b%20c/d%2Fe'), ['a', 'b c', 'd/e']);
      expect(restParts(''), isEmpty);
    });
  });

  group('case sensitivity', () {
    testWidgets('paths are case-sensitive by default', (tester) async {
      await open(tester, '/Products');
      expect(find.text('products '), findsNothing);
    });

    testWidgets('caseSensitive: false matches any case', (tester) async {
      await open(tester, '/PRODUCTS', caseSensitive: false);
      expect(find.text('products '), findsOneWidget);
      await open(tester, '/Docs/A/b', caseSensitive: false);
      expect(find.text('docs [A, b]'), findsOneWidget);
      await open(tester, '/DOCS/NEW', caseSensitive: false);
      expect(find.text('new doc'), findsOneWidget);
    });
  });

  group('nearestNotFound', () {
    Widget scoped(Uri uri, {required bool caseSensitive}) => nearestNotFound(
      uri,
      '/Shop',
      [
        (
          ['a', ':id'],
          (uri) => const Text('item'),
          caseSensitive: caseSensitive,
        ),
        (['a'], (uri) => const Text('a'), caseSensitive: caseSensitive),
      ],
      (uri) => const Text('root'),
      caseSensitive: caseSensitive,
    );

    String shown(Widget w) => (w as Text).data!;

    test('compares folder names by case unless told not to', () {
      expect(
        shown(scoped(Uri.parse('/Shop/A/1'), caseSensitive: true)),
        'root',
      );
      expect(
        shown(scoped(Uri.parse('/shop/a/1'), caseSensitive: true)),
        'root',
      );
      expect(
        shown(scoped(Uri.parse('/Shop/a/1'), caseSensitive: true)),
        'item',
      );
      expect(
        shown(scoped(Uri.parse('/shop/A/1'), caseSensitive: false)),
        'item',
      );
      expect(shown(scoped(Uri.parse('/SHOP/A'), caseSensitive: false)), 'a');
      expect(
        shown(scoped(Uri.parse('/other/A'), caseSensitive: false)),
        'root',
      );
    });

    test('each folder says how its own path is compared (its route.dart)', () {
      Widget mixed(Uri uri) => nearestNotFound(
        uri,
        '/',
        [
          // `strict/` opted back in to case, below `lax/`'s and the root's.
          (
            ['lax', 'strict'],
            (uri) => const Text('strict'),
            caseSensitive: true,
          ),
          (['lax'], (uri) => const Text('lax'), caseSensitive: false),
          (['other'], (uri) => const Text('other'), caseSensitive: true),
        ],
        (uri) => const Text('root'),
        caseSensitive: false,
      );
      expect(shown(mixed(Uri.parse('/LAX/x'))), 'lax');
      expect(shown(mixed(Uri.parse('/Lax/strict/x'))), 'lax');
      expect(shown(mixed(Uri.parse('/lax/strict/x'))), 'strict');
      expect(shown(mixed(Uri.parse('/lax/STRICT/x'))), 'lax');
      // The root's setting doesn't reach a folder that set its own.
      expect(shown(mixed(Uri.parse('/other/x'))), 'other');
      expect(shown(mixed(Uri.parse('/OTHER/x'))), 'root');
    });
  });

  group('typed catch-alls', () {
    // What the generated code does for `List<int> rest` and friends: parse the parts
    // with a typed reader, and show not-found when one of them doesn't parse.
    Widget parsed<T>(
      GoRouterState state,
      List<T> Function(GoRouterState s, String name) read,
    ) => buildWithParams(
      () => read(state, 'rest'),
      (v) => Text('${v.runtimeType} $v'),
      () => Text('not found ${state.uri.path}'),
    );

    GoRouter router(String at) => GoRouter(
      initialLocation: at,
      routes: [
        GoRoute(
          path: '/int/:rest(.+)',
          builder: (context, state) => parsed(state, Segment.asIntRest),
        ),
        GoRoute(
          path: '/double/:rest(.+)',
          builder: (context, state) => parsed(state, Segment.asDoubleRest),
        ),
        GoRoute(
          path: '/num/:rest(.+)',
          builder: (context, state) => parsed(state, Segment.asNumRest),
        ),
        GoRoute(
          path: '/bool/:rest(.+)',
          builder: (context, state) => parsed(state, Segment.asBoolRest),
        ),
        GoRoute(
          path: '/date/:rest(.+)',
          builder: (context, state) => parsed(state, Segment.asDateTimeRest),
        ),
        GoRoute(
          path: '/opt',
          builder: (context, state) => parsed(state, Segment.asIntRest),
        ),
        GoRoute(
          path: '/opt/:rest(.+)',
          builder: (context, state) => parsed(state, Segment.asIntRest),
        ),
      ],
    );

    Future<void> at(WidgetTester tester, String location) =>
        pumpRouter(tester, router(location));

    testWidgets('each part is read like a segment of that type', (
      tester,
    ) async {
      await at(tester, '/int/3/-7/12');
      expect(find.text('List<int> [3, -7, 12]'), findsOneWidget);
      await at(tester, '/double/1.5/2/-0.25');
      expect(find.text('List<double> [1.5, 2.0, -0.25]'), findsOneWidget);
      await at(tester, '/num/1/2.5');
      expect(find.text('List<num> [1, 2.5]'), findsOneWidget);
      await at(tester, '/bool/true/false');
      expect(find.text('List<bool> [true, false]'), findsOneWidget);
      await at(tester, '/date/2024-05-01/2024-12-31T10%3A30%3A00.000Z');
      expect(
        find.text(
          'List<DateTime> [2024-05-01 00:00:00.000, 2024-12-31 10:30:00.000Z]',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a part that does not parse is not found, as one segment is', (
      tester,
    ) async {
      await at(tester, '/int/3/x/5');
      expect(find.text('not found /int/3/x/5'), findsOneWidget);
      await at(tester, '/int/3.5');
      expect(find.text('not found /int/3.5'), findsOneWidget);
      await at(tester, '/double/abc');
      expect(find.text('not found /double/abc'), findsOneWidget);
      await at(tester, '/num/1/two');
      expect(find.text('not found /num/1/two'), findsOneWidget);
      // bool is `true` or `false`, in lower case, like a bool segment.
      await at(tester, '/bool/TRUE');
      expect(find.text('not found /bool/TRUE'), findsOneWidget);
      await at(tester, '/bool/true/1');
      expect(find.text('not found /bool/true/1'), findsOneWidget);
      await at(tester, '/date/yesterday');
      expect(find.text('not found /date/yesterday'), findsOneWidget);
    });

    testWidgets('the error names the parameter, the part and the type', (
      tester,
    ) async {
      late GoRouterState state;
      final r = GoRouter(
        initialLocation: '/int/1/b',
        routes: [
          GoRoute(
            path: '/int/:rest(.+)',
            builder: (context, s) {
              state = s;
              return const Text('here');
            },
          ),
        ],
      );
      await pumpRouter(tester, r);
      expect(
        () => Segment.asIntRest(state, 'rest'),
        throwsA(
          isA<BadSegment>()
              .having((e) => e.name, 'name', 'rest')
              .having((e) => e.value, 'value', 'b')
              .having((e) => e.type, 'type', 'int'),
        ),
      );
    });

    testWidgets('an optional catch-all is an empty list when absent', (
      tester,
    ) async {
      await at(tester, '/opt');
      expect(find.text('List<int> []'), findsOneWidget);
      await at(tester, '/opt/1/2');
      expect(find.text('List<int> [1, 2]'), findsOneWidget);
    });

    testWidgets('an encoded slash stays inside its part', (tester) async {
      // `1%2F2` is one part, which isn't an int: not found, not `[1, 2]`.
      await at(tester, '/int/1%2F2');
      expect(find.textContaining('not found'), findsOneWidget);
    });

    test('restPath and restKey write each part, whatever its type', () {
      expect(restPath([3, -7, 12]), '/3/-7/12');
      expect(restPath([1.5, 2.0]), '/1.5/2.0');
      expect(restPath([true, false]), '/true/false');
      expect(restPath(<num>[1, 2.5]), '/1/2.5');
      expect(restPath(const <int>[]), '');
      expect(restKey([3, -7, 12]), '3/-7/12');
      // A date is ISO 8601, encoded, so the colons don't split or confuse the path.
      final utc = DateTime.utc(2024, 12, 31, 10, 30);
      expect(restPath([utc]), '/2024-12-31T10%3A30%3A00.000Z');
      expect(restKey([utc]), '2024-12-31T10%3A30%3A00.000Z');
    });

    test('a data key is parsed back into the list it came from', () {
      final utc = DateTime.utc(2024, 12, 31, 10, 30);
      expect(restParts(restKey([3, -7, 12])).map(int.parse).toList(), [
        3,
        -7,
        12,
      ]);
      expect(restParts(restKey([1.5, 2.0])).map(double.parse).toList(), [
        1.5,
        2.0,
      ]);
      expect(restParts(restKey(<num>[1, 2.5])).map(num.parse).toList(), [
        1,
        2.5,
      ]);
      expect(restParts(restKey([true, false])).map(bool.parse).toList(), [
        true,
        false,
      ]);
      expect(restParts(restKey([utc])).map(DateTime.parse).toList(), [utc]);
    });
  });

  group('the requested case is kept', () {
    // go_router matches a caseSensitive: false route in any case, and leaves the
    // location as it was asked for: nothing is lowercased.
    late GoRouterState seen;

    GoRouter router(String at) => GoRouter(
      initialLocation: at,
      routes: [
        GoRoute(
          path: '/products/:id',
          caseSensitive: false,
          builder: (context, state) {
            seen = state;
            return Text('product ${state.pathParameters['id']}');
          },
        ),
        GoRoute(
          path: '/exact',
          builder: (context, state) => const Text('exact'),
        ),
        GoRoute(
          path: '/loose',
          caseSensitive: false,
          builder: (context, state) => const Text('loose'),
        ),
      ],
    );

    testWidgets('state.uri and the current location are as requested', (
      tester,
    ) async {
      final r = router('/Products/2?Tab=Info');
      await pumpRouter(tester, r);
      expect(find.text('product 2'), findsOneWidget);
      expect(seen.uri.toString(), '/Products/2?Tab=Info');
      expect(seen.uri.path, '/Products/2');
      // Only matchedLocation is rebuilt from the route's own path (the parameters as
      // typed): it spells the static parts the way the folders do.
      expect(seen.matchedLocation, '/products/2');
      expect(currentLocation(tester), '/Products/2?Tab=Info');
      expect(r.routeInformationProvider.value.uri.path, '/Products/2');
      // The template is the one the route was written with, not the requested path.
      expect(seen.fullPath, '/products/:id');
    });

    testWidgets('a parameter keeps the case it was typed in', (tester) async {
      await pumpRouter(tester, router('/PRODUCTS/AbC'));
      expect(find.text('product AbC'), findsOneWidget);
      expect(seen.uri.path, '/PRODUCTS/AbC');
    });

    testWidgets('going to another case by code keeps it too', (tester) async {
      final r = router('/exact');
      await pumpRouter(tester, r);
      r.go('/pRoDuCtS/7');
      await tester.pumpAndSettle();
      expect(find.text('product 7'), findsOneWidget);
      expect(currentLocation(tester), '/pRoDuCtS/7');
      expect(seen.uri.path, '/pRoDuCtS/7');
    });

    testWidgets('each route has its own setting', (tester) async {
      await pumpRouter(tester, router('/LOOSE'));
      expect(find.text('loose'), findsOneWidget);
      await pumpRouter(tester, router('/EXACT'));
      expect(find.text('exact'), findsNothing);
      expect(
        find.textContaining('no routes for location: /EXACT'),
        findsOneWidget,
      );
    });
  });

  group('trailing slashes', () {
    testWidgets('go_router drops them before matching', (tester) async {
      await open(tester, '/products/');
      expect(find.text('products '), findsOneWidget);
    });

    testWidgets('also in front of a query', (tester) async {
      await open(tester, '/products/?page=2');
      expect(find.text('products page=2'), findsOneWidget);
    });

    testWidgets('and in front of a fragment', (tester) async {
      await open(tester, '/products/#top');
      expect(find.text('products '), findsOneWidget);
    });

    testWidgets('and when navigating', (tester) async {
      await open(tester, '/');
      GoRouter.of(tester.element(find.text('home'))).go('/products/');
      await tester.pumpAndSettle();
      expect(find.text('products '), findsOneWidget);
      expect(currentLocation(tester), '/products');
    });
  });

  group('extra', () {
    testWidgets('reaches the page typed, and is null for a deep link', (
      tester,
    ) async {
      await open(tester, '/');
      final r = GoRouter.of(tester.element(find.text('home')));
      r.go('/item', extra: 7);
      await tester.pumpAndSettle();
      expect(find.text('item 7'), findsOneWidget);
      r.go('/item');
      await tester.pumpAndSettle();
      expect(find.text('item null'), findsOneWidget);
    });

    testWidgets('of another type is an error in debug builds', (tester) async {
      await open(tester, '/');
      GoRouter.of(tester.element(find.text('home'))).go('/item', extra: 'x');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<AssertionError>());
    });

    testWidgets('extraOrNull is null for another type, without an error', (
      tester,
    ) async {
      await open(tester, '/');
      final r = GoRouter.of(tester.element(find.text('home')));
      r.go('/seen', extra: 7);
      await tester.pumpAndSettle();
      expect(find.text('seen 7'), findsOneWidget);
      r.go('/seen', extra: 'x');
      await tester.pumpAndSettle();
      expect(find.text('seen null'), findsOneWidget);
      r.go('/seen');
      await tester.pumpAndSettle();
      expect(find.text('seen null'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
