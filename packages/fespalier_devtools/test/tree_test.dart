// The tree as `fsp` writes it: these parse the generator's own goldens, so a change of the tree's
// shape that the extension cannot read fails here, in the commit that makes it.
import 'package:fespalier_devtools/src/tree.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_client.dart';

RouteTree load(String name) => RouteTree.fromJson(golden(name));

void main() {
  test('every example\'s tree parses', () {
    for (final name in ['minimal', 'shop', 'features', 'tabs']) {
      final tree = load(name);
      expect(tree.protocol, 1, reason: name);
      expect(tree.appDir, 'lib/app', reason: name);
      expect(tree.package, name, reason: name);
      expect(tree.routes, isNotEmpty, reason: name);
    }
  });

  group('the features tree', () {
    final tree = load('features');

    test('finds a route by class, with its file, markers and parameters', () {
      final route = tree.routeByClass('ReviewsRoute')!;
      expect(route.pattern, '/catalog/:productId/reviews');
      expect(route.file, 'catalog/\$productId/reviews/page.dart');
      expect(route.folder, 'catalog/\$productId/reviews');
      expect(route.markers, ['data']);
      expect(
        [for (final p in route.params) '${p.name}: ${p.type}'],
        ['productId: String', 'page: int?'],
      );
      expect([for (final p in route.params) p.inQuery], [false, true]);
      expect(route.hasPathParams, isTrue);
      expect(route.redirect, isFalse);
      expect(tree.routeByClass('NoSuchRoute'), isNull);
      expect(tree.routeByClass(null), isNull);
    });

    test('has the spellings of a localized route', () {
      final route = tree.routeByClass('HelpTopicRoute')!;
      expect(route.spellings, {'fr': '/aide/:topic', 'de': '/hilfe/:topic'});
      expect(tree.routeByClass('LoginRoute')!.spellings, isEmpty);
    });

    test('knows a redirect, a guard and a route without a path parameter', () {
      expect(tree.routeByClass('OldSearchRoute')!.redirect, isTrue);
      expect(tree.routeByClass('AdminRoute')!.markers, ['guard']);
      expect(tree.routeByClass('LoginRoute')!.hasPathParams, isFalse);
      expect(tree.routeByClass('LoginRoute')!.params.single.inQuery, isTrue);
    });

    test('finds a route by pattern', () {
      expect(tree.routeByPattern('/orders/:id')!.route, 'OrderRoute');
      expect(tree.routeByPattern('/nowhere'), isNull);
    });

    test('has the sites of a route', () {
      final refund = tree.routeByClass('RefundRoute')!;
      final sites = tree.sitesOf(refund);
      expect({for (final s in sites) s.kind}, {'guard', 'data', 'action'});
      final guard = sites.firstWhere((s) => s.kind == 'guard');
      expect(guard.file, contains('guard.dart'));
      expect(guard.pattern, '/orders/:id/refund');
      expect(guard.id, matches(RegExp(r'^g\d+@\d+$')));
      final data = sites.firstWhere((s) => s.kind == 'data');
      expect(data.file, 'orders/\$id/refund/data.dart');
      expect(data.traced, isTrue);
      final action = sites.firstWhere((s) => s.kind == 'action');
      expect(action.name, 'action');
      expect(tree.sites[action.id], same(action));
    });

    test('knows a data.dart that returns a provider is not traced', () {
      final catalog = tree.sitesOf(tree.routeByClass('CatalogRoute')!);
      expect(catalog.single.kind, 'data');
      expect(catalog.single.traced, isFalse);
    });

    test('knows a section: a layout\'s data.dart is on no route', () {
      final section = tree.sites.values.firstWhere((s) => s.section != null);
      expect(section.kind, 'data');
      expect(section.route, isNull);
      expect(section.section, 'reports');
    });

    test('lists the layouts around a route, outermost first', () {
      final route = tree.routeByClass('ProfileRoute')!;
      final around = tree.ancestorsOf(route);
      expect(around.map((i) => i.file), [
        'layout.dart',
        'page.dart',
        '(account)/layout.dart',
      ]);
      expect(around.first, isA<ShellNode>());
      expect(around[1], isA<RouteNode>());
      expect(
        tree.ancestorsOf(tree.routeByClass('HomeRoute')!).single,
        isA<ShellNode>(),
      );
    });

    test('lists the routes a route nests in', () {
      final route = tree.routeByClass('ReviewsRoute')!;
      final nests = tree.ancestorsOf(route).whereType<RouteNode>();
      expect(nests.map((r) => r.route), [
        'HomeRoute',
        'CatalogRoute',
        'ProductDetailRoute',
      ]);
    });
  });

  group('the tabs tree', () {
    final tree = load('tabs');

    test('has the tab layout with its branches', () {
      final tabs = tree.items.whereType<TabsNode>().single;
      expect(tabs.file, '(tabs)/layout.dart');
      expect(tabs.branches.map((b) => '${b.index}:${b.name}'), [
        '0:(home)',
        '1:search',
        '2:profile',
        '3:library',
      ]);
    });

    test('says which tab holds a route, in a tab layout inside a tab', () {
      final tabs = tree.items.whereType<TabsNode>().single;
      expect(tree.tabOf(tabs, tree.routeByClass('SearchRoute')!), 1);
      expect(tree.tabOf(tabs, tree.routeByClass('SecurityRoute')!), 2);
      expect(tree.tabOf(tabs, tree.routeByClass('BooksRoute')!), 3);
      final inner = tree
          .ancestorsOf(tree.routeByClass('AuthorsRoute')!)
          .whereType<TabsNode>()
          .toList();
      expect(inner.map((t) => t.file), [
        '(tabs)/layout.dart',
        '(tabs)/library/layout.dart',
      ]);
      expect(tree.tabOf(inner.last, tree.routeByClass('AuthorsRoute')!), 1);
      expect(tree.tabOf(tabs, tree.routeByClass('SettingsRoute')!), isNull);
    });
  });

  test('an item of a type it does not know is an error, not a guess', () {
    expect(
      () => TreeItem.fromJson({'type': 'portal'}),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'a route with no spellings, params or children reads as having none',
    () {
      final node =
          TreeItem.fromJson({
                'type': 'route',
                'pattern': '/',
                'route': 'HomeRoute',
                'file': 'page.dart',
                'folder': '',
                'markers': <Object?>[],
              })
              as RouteNode;
      expect(node.params, isEmpty);
      expect(node.spellings, isEmpty);
      expect(node.children, isEmpty);
    },
  );
}
