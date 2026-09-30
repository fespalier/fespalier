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
    GoRouterState state(Map<String, String> params) => GoRouterState(
          GoRouter(routes: []).configuration,
          uri: Uri.parse('/'),
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
      final built = buildWithSegments(
        () => (id: Segment.asInt(s, 'id')),
        (v) => Text('page ${v.id}'),
        () => const Text('not found'),
      );
      expect((built as Text).data, 'not found');
      expect(
        guardWithSegments(() => Segment.asInt(s, 'id'), (id) => '/login'),
        isNull,
      );
    });
  });
}
