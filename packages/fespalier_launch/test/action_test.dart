import 'package:fespalier/fespalier.dart' show NavigationSource;
import 'package:fespalier_launch/fespalier_launch.dart';
import 'package:flutter_test/flutter_test.dart';

LaunchRoute _route({
  Set<String> hosts = const {'shop.example.com'},
  LaunchOpen open = LaunchOpen.go,
}) => widgetLinkRoute(
  schemes: const {'myapp'},
  hosts: hosts,
  matches: (uri) =>
      uri.path.startsWith('/orders/') || uri.path == '/' || uri.path == '/a',
  open: open,
);

String? _at(Uri uri, {Set<String> hosts = const {'shop.example.com'}}) =>
    _route(hosts: hosts)(WidgetAction(uri))?.location;

/// A route whose matcher takes every path, so a refusal is the path rules' own.
String? _any(Uri uri) => widgetLinkRoute(
  schemes: const {'myapp'},
  hosts: const {'shop.example.com'},
  matches: (_) => true,
)(WidgetAction(uri))?.location;

void main() {
  group('equality', () {
    test('a shortcut is its type, and the raw object does not count', () {
      expect(
        const ShortcutAction('last_order', raw: 1),
        const ShortcutAction('last_order', raw: 2),
      );
      expect(
        const ShortcutAction('a').hashCode,
        const ShortcutAction('a', raw: 'x').hashCode,
      );
      expect(const ShortcutAction('a'), isNot(const ShortcutAction('b')));
    });

    test('a widget is its URI, and the raw object does not count', () {
      final uri = Uri.parse('myapp:///orders/42');
      expect(
        WidgetAction(uri, raw: 1),
        WidgetAction(Uri.parse('myapp:///orders/42')),
      );
      expect(
        WidgetAction(uri).hashCode,
        WidgetAction(Uri.parse('myapp:///orders/42'), raw: 'x').hashCode,
      );
      expect(
        WidgetAction(uri),
        isNot(WidgetAction(Uri.parse('myapp:///orders/7'))),
      );
    });

    test('a shortcut is never a widget, even with the same text', () {
      expect(
        const ShortcutAction('myapp:///orders/42') ==
            WidgetAction(Uri.parse('myapp:///orders/42')),
        isFalse,
      );
    });
  });

  test('the source is the NavigationSource value of each kind', () {
    expect(const ShortcutAction('x').source, NavigationSource.shortcut);
    expect(
      WidgetAction(Uri.parse('myapp:///a')).source,
      NavigationSource.widget,
    );
  });

  test('toString never prints a shortcut type, a widget path or a query', () {
    final action = WidgetAction(Uri.parse('myapp:///orders/42?token=secret'));
    expect(action.toString(), 'WidgetAction(myapp)');
    expect(action.toString(), isNot(contains('orders')));
    expect(action.toString(), isNot(contains('secret')));
    // A shortcut's type can carry an id (`chat_123`): no field is printed.
    final shortcut = const ShortcutAction('chat_123', raw: 'chat_123');
    expect(shortcut.toString(), 'ShortcutAction()');
    expect(shortcut.toString(), isNot(contains('chat')));
    expect(shortcut.toString(), isNot(contains('123')));
  });

  group('widgetLinkRoute accepts', () {
    test('a custom scheme with an empty host: the path is the location', () {
      expect(_at(Uri.parse('myapp:///orders/42')), '/orders/42');
    });

    test('the query is kept; the fragment is dropped', () {
      expect(_at(Uri.parse('myapp:///orders/42?tab=2#x')), '/orders/42?tab=2');
    });

    test('an https URL on an allowed host', () {
      expect(
        _at(Uri.parse('https://shop.example.com/orders/42')),
        '/orders/42',
      );
    });

    test('a custom scheme whose host is an allowed one', () {
      expect(_at(Uri.parse('myapp://shop.example.com/a')), '/a');
    });

    test('the host is compared in lower case, as the set is', () {
      final route = widgetLinkRoute(
        schemes: const {'MyApp'},
        hosts: const {'Shop.Example.COM'},
        matches: (_) => true,
      );
      expect(
        route(
          WidgetAction(Uri.parse('HTTPS://SHOP.example.com/orders/42')),
        )?.location,
        '/orders/42',
      );
      expect(
        route(WidgetAction(Uri.parse('myapp://shop.example.com/a')))?.location,
        '/a',
      );
    });

    test('an empty path is the app\'s root, as fespalier_push reads it', () {
      expect(_at(Uri.parse('https://shop.example.com')), '/');
      expect(_at(Uri.parse('https://shop.example.com/')), '/');
      expect(_at(Uri.parse('https://shop.example.com?tab=2')), '/?tab=2');
      expect(_any(Uri.parse('myapp://shop.example.com')), '/');
      expect(_any(Uri.parse('myapp:///')), '/');
      // The root still goes through `matches`.
      final noRoot = widgetLinkRoute(
        hosts: const {'shop.example.com'},
        matches: (uri) => uri.path.startsWith('/orders/'),
      );
      expect(
        noRoot(WidgetAction(Uri.parse('https://shop.example.com'))),
        isNull,
      );
    });

    test('open: is carried into the target', () {
      final target = _route(open: LaunchOpen.push)(
        WidgetAction(Uri.parse('myapp:///orders/42')),
      );
      expect(target?.open, LaunchOpen.push);
      expect(target?.extra, isNull);
    });
  });

  group('widgetLinkRoute refuses', () {
    test('a scheme that is not allowed, and http', () {
      expect(_at(Uri.parse('evil:///orders/1')), isNull);
      expect(_at(Uri.parse('http://shop.example.com/a')), isNull);
    });

    test('a foreign https host', () {
      expect(_at(Uri.parse('https://other.host/a')), isNull);
    });

    test('a custom scheme whose host is not an allowed one', () {
      expect(_at(Uri.parse('myapp://orders/42')), isNull);
    });

    test('credentials in the URI', () {
      expect(_at(Uri.parse('https://u:p@shop.example.com/a')), isNull);
    });

    test('a path that is not in-app or that escapes it', () {
      // The matcher accepts everything here, so only the path rules can refuse.
      expect(_any(Uri.parse('myapp:////evil.com')), isNull);
      expect(_any(Uri.parse('myapp:///%2F%2Fevil.com')), isNull);
      expect(_any(Uri.parse('myapp:///orders/%5C1')), isNull);
      expect(_any(Uri.parse('myapp:///orders/%0A1')), isNull);
      expect(_any(Uri.parse('myapp:///orders/%7F1')), isNull);
      expect(_any(Uri.parse('myapp:orders')), isNull);
    });

    test('an empty URI', () {
      expect(_any(Uri()), isNull);
    });

    test('a path that matches rejects', () {
      expect(_at(Uri.parse('myapp:///nowhere')), isNull);
    });

    test('a shortcut, whatever the route says', () {
      expect(_route()(const ShortcutAction('last_order')), isNull);
    });
  });

  group('LaunchTarget', () {
    test('a target keeps its location, extra and open', () {
      final target = LaunchTarget(
        '/orders/42',
        extra: 'x',
        open: LaunchOpen.push,
      );
      expect(target.location, '/orders/42');
      expect(target.extra, 'x');
      expect(target.open, LaunchOpen.push);
      expect(LaunchTarget('/a').open, LaunchOpen.go);
    });
  });
}
