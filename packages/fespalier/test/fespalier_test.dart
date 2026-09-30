import 'package:fespalier/fespalier.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joinLocation mounts paths under a base', () {
    expect(joinLocation('/', '/products/1'), '/products/1');
    expect(joinLocation('', '/'), '/');
    expect(joinLocation('/shop', '/'), '/shop');
    expect(joinLocation('/shop/', '/cart'), '/shop/cart');
  });

  group('segments', () {
    GoRouterState state(Map<String, String> params, [String uri = '/']) =>
        GoRouterState(
          GoRouter(routes: []).configuration,
          uri: Uri.parse(uri),
          matchedLocation: '/',
          fullPath: '/',
          pathParameters: params,
          pageKey: const ValueKey('k'),
        );

    test('read typed values', () {
      final s = state({'id': '42', 'x': '1.5', 'on': 'true', 'name': 'a'});
      expect(Segment.asInt(s, 'id'), 42);
      expect(Segment.asDouble(s, 'x'), 1.5);
      expect(Segment.asBool(s, 'on'), isTrue);
      expect(Segment.asString(s, 'name'), 'a');
    });

    test('bad values fall back to not-found and skip guards', () {
      final s = state({'id': 'abc'});
      final built = buildWithParams(
        () => (id: Segment.asInt(s, 'id')),
        (v) => Text('page ${v.id}'),
        () => const Text('not found'),
      );
      expect((built as Text).data, 'not found');
      expect(
        guardWithParams(() => Segment.asInt(s, 'id'), (id) => '/login'),
        isNull,
      );
    });

    test('query parameters are lenient', () {
      final s = state({}, '/?page=2&bad=x&on=true&tag=a&tag=b&n=1&n=x&n=3');
      expect(Query.asInt(s, 'page'), 2);
      expect(Query.asInt(s, 'bad'), isNull);
      expect(Query.asInt(s, 'missing'), isNull);
      expect(Query.asBool(s, 'on'), isTrue);
      expect(Query.asStringList(s, 'tag'), ['a', 'b']);
      expect(Query.asIntList(s, 'n'), [1, 3]);
      expect(Query.asStringList(s, 'missing'), isEmpty);
    });
  });

  test('withQuery leaves out nulls and empty lists', () {
    expect(withQuery('/p', {'a': null, 'b': <String>[]}), '/p');
    expect(
      withQuery('/p', {
        'q': 'a b',
        'page': 2,
        'tag': ['x', 'y'],
      }),
      '/p?q=a+b&page=2&tag=x&tag=y',
    );
  });

  group('Transitions', () {
    const key = ValueKey('k');
    const child = Text('a');

    test('each helper returns its page type with the key and child', () {
      final fade = Transitions.fade(key, child);
      expect(fade, isA<CustomTransitionPage<void>>());
      expect(fade.key, key);
      expect((fade as CustomTransitionPage<void>).child, child);

      final slide = Transitions.slide(key, child);
      expect(slide, isA<CustomTransitionPage<void>>());
      expect(slide.key, key);
      expect((slide as CustomTransitionPage<void>).child, child);

      final none = Transitions.none(key, child);
      expect(none, isA<NoTransitionPage<void>>());
      expect(none.key, key);
      expect((none as NoTransitionPage<void>).child, child);

      final material = Transitions.material(key, child);
      expect(material, isA<MaterialPage<void>>());
      expect(material.key, key);
      expect((material as MaterialPage<void>).child, child);

      final cupertino = Transitions.cupertino(key, child);
      expect(cupertino, isA<CupertinoPage<void>>());
      expect(cupertino.key, key);
      expect((cupertino as CupertinoPage<void>).child, child);
    });

    test('fade and slide apply their durations', () {
      final defaults = [
        Transitions.fade(key, child),
        Transitions.slide(key, child),
      ].cast<CustomTransitionPage<void>>();
      expect(defaults[0].transitionDuration, const Duration(milliseconds: 250));
      expect(defaults[1].transitionDuration, const Duration(milliseconds: 300));

      const d = Duration(milliseconds: 40);
      final custom = [
        Transitions.fade(key, child, duration: d),
        Transitions.slide(key, child, duration: d),
      ].cast<CustomTransitionPage<void>>();
      for (final page in custom) {
        expect(page.transitionDuration, d);
        expect(page.reverseTransitionDuration, d);
      }
    });

    testWidgets('fade animates the incoming page', (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (c, s) => const Text('a')),
          GoRoute(
            path: '/b',
            pageBuilder: (c, s) => Transitions.fade(s.pageKey, const Text('b')),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      router.go('/b');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      double opacity() => tester
          .widget<FadeTransition>(
            find.ancestor(
              of: find.text('b'),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value;
      expect(opacity(), inExclusiveRange(0, 1));

      await tester.pumpAndSettle();
      expect(opacity(), 1);
    });
  });
}
