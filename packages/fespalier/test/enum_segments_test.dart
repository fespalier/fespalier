import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

enum Category { shoes, hats }

/// `a` and `A` are two values.
enum Tricky { a, A, bee }

/// Segments, query parameters and catch-alls that are enums: what `Category category`,
/// `Sort? sort` and `List<Category> path` in a view are read with.
void main() {
  GoRouterState state(
    String uri, {
    Map<String, String> params = const {},
    String fullPath = '/',
  }) => GoRouterState(
    GoRouter(routes: []).configuration,
    uri: Uri.parse(uri),
    matchedLocation: '/',
    fullPath: fullPath,
    pathParameters: params,
    pageKey: const ValueKey('k'),
  );

  group('Segment.asEnum', () {
    test('reads the value whose name the segment spells', () {
      final s = state('/', params: {'category': 'hats'});
      expect(Segment.asEnum(s, 'category', Category.values), Category.hats);
      final shoes = state('/', params: {'category': 'shoes'});
      expect(
        Segment.asEnum(shoes, 'category', Category.values),
        Category.shoes,
      );
    });

    test('an unknown name is a BadSegment, which is not-found', () {
      final s = state('/', params: {'category': 'socks'});
      expect(
        () => Segment.asEnum(s, 'category', Category.values),
        throwsA(
          isA<BadSegment>()
              .having((e) => e.name, 'name', 'category')
              .having((e) => e.value, 'value', 'socks')
              .having((e) => e.type, 'type', 'Category'),
        ),
      );
      // What the generated builder does with it.
      final built = buildWithParams(
        () => (category: Segment.asEnum(s, 'category', Category.values)),
        (v) => Text('page ${v.category}'),
        () => const Text('not found'),
      );
      expect((built as Text).data, 'not found');
      expect(
        guardWithParams(
          () => Segment.asEnum(s, 'category', Category.values),
          (c) => '/login',
        ),
        isNull,
      );
    });

    test('by default the case has to be the name\'s', () {
      final s = state('/', params: {'category': 'Shoes'});
      expect(
        () => Segment.asEnum(s, 'category', Category.values),
        throwsA(isA<BadSegment>()),
      );
      expect(
        () =>
            Segment.asEnum(s, 'category', Category.values, caseSensitive: true),
        throwsA(isA<BadSegment>()),
      );
    });

    test('with caseSensitive: false any case names it', () {
      for (final raw in ['shoes', 'Shoes', 'SHOES', 'sHoEs']) {
        final s = state('/', params: {'category': raw});
        expect(
          Segment.asEnum(s, 'category', Category.values, caseSensitive: false),
          Category.shoes,
          reason: raw,
        );
      }
      final s = state('/', params: {'category': 'socks'});
      expect(
        () => Segment.asEnum(
          s,
          'category',
          Category.values,
          caseSensitive: false,
        ),
        throwsA(isA<BadSegment>()),
      );
    });

    test('an exact name wins over one that differs in case', () {
      for (final insensitive in [true, false]) {
        Tricky read(String raw) => Segment.asEnum(
          state('/', params: {'t': raw}),
          't',
          Tricky.values,
          caseSensitive: !insensitive,
        );
        expect(read('a'), Tricky.a);
        expect(read('A'), Tricky.A);
      }
      expect(
        Segment.asEnum(
          state('/', params: {'t': 'BEE'}),
          't',
          Tricky.values,
          caseSensitive: false,
        ),
        Tricky.bee,
      );
    });

    test('a missing segment is a BadSegment too', () {
      expect(
        () => Segment.asEnum(state('/'), 'category', Category.values),
        throwsA(isA<BadSegment>()),
      );
    });
  });

  group('Segment.asEnumRest', () {
    GoRouterState at(String path) => state(
      path,
      params: {'path': path.substring('/browse/'.length)},
      fullPath: '/browse/:path(.+)',
    );

    test('reads every part by name, in order', () {
      expect(
        Segment.asEnumRest(
          at('/browse/shoes/hats/shoes'),
          'path',
          Category.values,
        ),
        [Category.shoes, Category.hats, Category.shoes],
      );
    });

    test('a part that names no value is a BadSegment', () {
      expect(
        () => Segment.asEnumRest(
          at('/browse/shoes/socks'),
          'path',
          Category.values,
        ),
        throwsA(
          isA<BadSegment>()
              .having((e) => e.value, 'value', 'socks')
              .having((e) => e.type, 'type', 'Category'),
        ),
      );
      expect(
        () => Segment.asEnumRest(at('/browse/Shoes'), 'path', Category.values),
        throwsA(isA<BadSegment>()),
      );
    });

    test('caseSensitive: false, and an optional one that is absent', () {
      expect(
        Segment.asEnumRest(
          at('/browse/SHOES/Hats'),
          'path',
          Category.values,
          caseSensitive: false,
        ),
        [Category.shoes, Category.hats],
      );
      expect(
        Segment.asEnumRest(
          state('/browse', fullPath: '/browse/:path(.+)'),
          'path',
          Category.values,
        ),
        isEmpty,
      );
    });
  });

  group('Query', () {
    test('asEnum is null for what is missing or names nothing', () {
      final s = state('/?sort=hats&bad=socks&up=Shoes');
      expect(Query.asEnum(s, 'sort', Category.values), Category.hats);
      expect(Query.asEnum(s, 'bad', Category.values), isNull);
      expect(Query.asEnum(s, 'missing', Category.values), isNull);
      // By default the case has to match, as for a segment.
      expect(Query.asEnum(s, 'up', Category.values), isNull);
      expect(
        Query.asEnum(s, 'up', Category.values, caseSensitive: false),
        Category.shoes,
      );
    });

    test('asEnumList leaves out what names nothing', () {
      final s = state('/?c=shoes&c=socks&c=hats&c=Hats');
      expect(Query.asEnumList(s, 'c', Category.values), [
        Category.shoes,
        Category.hats,
      ]);
      expect(Query.asEnumList(s, 'c', Category.values, caseSensitive: false), [
        Category.shoes,
        Category.hats,
        Category.hats,
      ]);
      expect(Query.asEnumList(s, 'missing', Category.values), isEmpty);
    });
  });

  group('writing', () {
    test('a location writes an enum as its name', () {
      expect(withQuery('/shop', {'sort': Category.hats}), '/shop?sort=hats');
      expect(
        withQuery('/shop', {
          'c': [Category.shoes, Category.hats],
          'n': 2,
          'none': null,
        }),
        '/shop?c=shoes&c=hats&n=2',
      );
      expect(withQuery('/shop', {'c': const <Category>[]}), '/shop');
      expect(restPath([Category.shoes, Category.hats]), '/shoes/hats');
      expect(restKey([Category.shoes, Category.hats]), 'shoes/hats');
      expect(restPath(const <Category>[]), '');
    });

    test('what is written is read back', () {
      final path = [Category.hats, Category.shoes, Category.hats];
      expect(
        restParts(restKey(path)).map(Category.values.byName).toList(),
        path,
      );
      final s = state(
        '/browse${restPath(path)}',
        params: {'path': restKey(path)},
        fullPath: '/browse/:path(.+)',
      );
      expect(Segment.asEnumRest(s, 'path', Category.values), path);
      final q = state(withQuery('/shop', {'c': path, 'one': Category.shoes}));
      expect(Query.asEnumList(q, 'c', Category.values), path);
      expect(Query.asEnum(q, 'one', Category.values), Category.shoes);
    });

    test(
      'enums are hashable keys: equal lists of them are one QueryList key',
      () {
        expect(
          QueryList([Category.hats, Category.shoes]),
          QueryList([Category.hats, Category.shoes]),
        );
        expect(
          QueryList([Category.hats, Category.shoes]).hashCode,
          QueryList([Category.hats, Category.shoes]).hashCode,
        );
        expect(QueryList([Category.hats]), isNot(QueryList([Category.shoes])));
      },
    );
  });

  group('in a router', () {
    GoRouter router(String at, {bool caseSensitive = true}) => GoRouter(
      initialLocation: at,
      routes: [
        GoRoute(
          path: '/shop/:category',
          caseSensitive: caseSensitive,
          builder: (context, state) => buildWithParams(
            () => (
              category: Segment.asEnum(
                state,
                'category',
                Category.values,
                caseSensitive: caseSensitive,
              ),
              sort: Query.asEnum(state, 'sort', Category.values),
            ),
            (v) => Text('shop ${v.category.name} ${v.sort?.name}'),
            () => Text('not found ${state.uri}'),
          ),
        ),
        GoRoute(
          path: '/browse/:path(.+)',
          builder: (context, state) => buildWithParams(
            () => Segment.asEnumRest(state, 'path', Category.values),
            (v) => Text('browse ${v.map((c) => c.name).join('+')}'),
            () => Text('not found ${state.uri}'),
          ),
        ),
      ],
    );

    testWidgets('a known name is the value, an unknown one is not-found', (
      tester,
    ) async {
      await pumpRouter(tester, router('/shop/hats?sort=shoes'));
      expect(find.text('shop hats shoes'), findsOneWidget);
      await pumpRouter(tester, router('/shop/socks'));
      expect(find.text('not found /shop/socks'), findsOneWidget);
      await pumpRouter(tester, router('/shop/Hats'));
      expect(find.text('not found /shop/Hats'), findsOneWidget);
    });

    testWidgets('a route that matches in any case reads any case', (
      tester,
    ) async {
      await pumpRouter(tester, router('/shop/HATS', caseSensitive: false));
      expect(find.text('shop hats null'), findsOneWidget);
    });

    testWidgets('a catch-all of enums', (tester) async {
      await pumpRouter(tester, router('/browse/shoes/hats'));
      expect(find.text('browse shoes+hats'), findsOneWidget);
      await pumpRouter(tester, router('/browse/shoes/hats/socks'));
      expect(find.text('not found /browse/shoes/hats/socks'), findsOneWidget);
    });
  });
}
