import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trellis/trellis.dart';

void main() {
  test('joinLocation mounts paths under a base', () {
    expect(joinLocation('/', '/products/1'), '/products/1');
    expect(joinLocation('', '/'), '/');
    expect(joinLocation('/shop', '/'), '/shop');
    expect(joinLocation('/shop/', '/cart'), '/shop/cart');
  });

  test('RouteKey equality is the resolved path only', () {
    final a = RouteKey('/products/1', Object());
    final b = RouteKey('/products/1', Object());
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == RouteKey('/products/2', Object()), isFalse);
  });

  group('segment parsing', () {
    GoRouterState state(Map<String, String> params) => GoRouterState(
          GoRouter(routes: []).configuration,
          uri: Uri.parse('/'),
          matchedLocation: '/',
          fullPath: '/',
          pathParameters: params,
          pageKey: const ValueKey('k'),
        );

    test('reads typed values', () {
      final s = state({'id': '42', 'x': '1.5', 'on': 'true', 'name': 'a'});
      expect(Segment.asInt(s, 'id'), 42);
      expect(Segment.asDouble(s, 'x'), 1.5);
      expect(Segment.asBool(s, 'on'), isTrue);
      expect(Segment.asString(s, 'name'), 'a');
    });

    test('bad values fall back to not-found', () {
      final s = state({'id': 'abc'});
      expect(
        buildWithParams(
          () => Segment.asInt(s, 'id'),
          (p) => const Text('page'),
          () => const Text('not found'),
        ),
        isA<Text>().having((t) => t.data, 'data', 'not found'),
      );
      expect(
        guardWithParams(() => Segment.asInt(s, 'id'), (p) => '/login'),
        isNull,
      );
    });
  });
}
