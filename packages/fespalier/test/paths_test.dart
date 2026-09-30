import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What go_router does with the paths the generated code hands it: catch-all
/// parameters (`:rest(.+)`), `caseSensitive`, trailing slashes and `extra`.
void main() {
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
        (['a', ':id'], (uri) => const Text('item')),
        (['a'], (uri) => const Text('a')),
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
  });
}
