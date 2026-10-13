import 'package:fespalier_push/fespalier_push.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PushRoute route({Set<String> hosts = const {'shop.example.com'}}) =>
      linkRoute(
        hosts: hosts,
        matches: (uri) => uri.path.startsWith('/orders/') || uri.path == '/',
      );
  String? at(Object? link, {String key = 'link', PushRoute? r}) =>
      (r ?? route())(PushMessage(data: {key: link}))?.location;

  test('an in-app path is kept, with its query', () {
    expect(at('/orders/42'), '/orders/42');
    expect(at('/orders/42?tab=items#top'), '/orders/42?tab=items');
  });

  test('an https URL on an allowed host becomes its path', () {
    expect(at('https://shop.example.com/orders/42?x=1'), '/orders/42?x=1');
    expect(at('HTTPS://Shop.Example.COM/orders/42'), '/orders/42');
    expect(at('https://shop.example.com'), '/');
  });

  test('anything else is ignored, never navigated to', () {
    for (final bad in <Object?>[
      '//evil.example.com/orders/1',
      '//orders/1',
      'https://other.host/orders/1',
      'http://shop.example.com/orders/1',
      'javascript:alert(1)',
      'myapp://orders/1',
      '/\\evil',
      r'/orders\1',
      'orders/1',
      '',
      '/orders/1\n',
      'https://user:pw@shop.example.com/orders/1',
      'https://shop.example.com//evil',
      42,
      null,
    ]) {
      expect(at(bad), isNull, reason: '$bad');
    }
  });

  test('a path the router does not know is ignored', () {
    expect(at('/unknown'), isNull);
  });

  test('no hosts: only in-app paths', () {
    final r = route(hosts: const {});
    expect(at('/orders/1', r: r), '/orders/1');
    expect(at('https://shop.example.com/orders/1', r: r), isNull);
  });

  test('key and open are configurable', () {
    final r = linkRoute(
      key: 'deeplink',
      matches: (_) => true,
      open: PushOpen.push,
    );
    final target = r(const PushMessage(data: {'deeplink': '/a'}));
    expect(target?.location, '/a');
    expect(target?.open, PushOpen.push);
    expect(r(const PushMessage(data: {'link': '/a'})), isNull);
  });
}
