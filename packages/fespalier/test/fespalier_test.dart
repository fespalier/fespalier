import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';
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
        'tag': ['x', 'y']
      }),
      '/p?q=a+b&page=2&tag=x&tag=y',
    );
  });
}
