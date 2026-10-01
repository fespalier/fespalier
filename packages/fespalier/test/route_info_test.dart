import 'package:fespalier/fespalier.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ProductRoute extends TypedLocation {
  const ProductRoute();
  @override
  String get location => '/products/1';
}

class Meta {
  const Meta(this.code);
  final String code;
}

const _all = <RouteInfo<Object?>>[
  RouteInfo(
    type: ProductRoute,
    path: '/products/:id',
    folder: r'(buyer)/products/$id',
    groups: ['(buyer)'],
    layouts: ['', '(buyer)'],
    segments: [RouteParam('id', 'int')],
    query: [RouteParam('tab', 'String?')],
    tabs: [RouteTab('(tabs)', 1, 'products')],
    dataKeys: ['id'],
    meta: Meta('B04'),
  ),
  RouteInfo(
    type: String,
    path: '/old',
    folder: 'old',
    presentation: RoutePresentation.redirect,
  ),
];

void main() {
  group('RouteInfo', () {
    test('holds what the manifest lists, and is const', () {
      final info = _all.first;
      expect(info.type, ProductRoute);
      expect(info.path, '/products/:id');
      expect(info.folder, r'(buyer)/products/$id');
      expect(info.presentation, RoutePresentation.page);
      expect(info.isRedirect, isFalse);
      expect(info.groups, ['(buyer)']);
      expect(info.layouts, ['', '(buyer)']);
      expect(info.segments.single.name, 'id');
      expect(info.segments.single.type, 'int');
      expect(info.query.single.toString(), 'String? tab');
      expect(info.tabs.single.layout, '(tabs)');
      expect(info.tabs.single.index, 1);
      expect(info.tabs.single.branch, 'products');
      expect(info.dataKeys, ['id']);
      expect(identical(_all.first, _all.first), isTrue);
    });

    test('defaults: a page with nothing else', () {
      final old = _all.last;
      expect(old.isRedirect, isTrue);
      expect(old.groups, isEmpty);
      expect(old.layouts, isEmpty);
      expect(old.segments, isEmpty);
      expect(old.query, isEmpty);
      expect(old.tabs, isEmpty);
      // No data.dart is null; a data.dart keyed by nothing is empty.
      expect(old.dataKeys, isNull);
      expect(old.meta, isNull);
    });

    test('metaAs reads the meta as the type it is', () {
      expect(_all.first.metaAs<Meta>()!.code, 'B04');
      expect(_all.first.meta, isA<Meta>());
      expect(_all.first.metaAs<String>(), isNull);
      expect(_all.last.metaAs<Meta>(), isNull);
      // A typed RouteInfo keeps its type.
      const typed = RouteInfo<Meta>(
        type: String,
        path: '/',
        folder: '',
        meta: Meta('A'),
      );
      expect(typed.meta!.code, 'A');
    });
  });

  group('routeTemplate', () {
    Future<GoRouterState> stateAt(WidgetTester tester, String location) async {
      late GoRouterState state;
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: '/shop/products/:id',
            builder: (context, s) {
              state = s;
              return const SizedBox();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('is the path template, minus the mount point', (tester) async {
      final state = await stateAt(tester, '/shop/products/7');
      expect(routeTemplate(state), '/shop/products/:id');
      expect(routeTemplate(state, '/'), '/shop/products/:id');
      expect(routeTemplate(state, '/shop'), '/products/:id');
      expect(routeTemplate(state, '/shop/'), '/products/:id');
      // Only a whole segment is the mount point.
      expect(routeTemplate(state, '/sho'), '/shop/products/:id');
      expect(routeTemplate(state, '/other'), '/shop/products/:id');
    });
  });

  group('lookupRoute', () {
    const docs = RouteInfo<Object?>(
      type: ProductRoute,
      path: '/docs/*rest',
      folder: 'docs',
      segments: [RouteParam('rest', 'List<String>', catchAll: true)],
    );
    const files = RouteInfo<Object?>(
      type: String,
      path: '/files/*path?',
      folder: 'files',
      segments: [RouteParam('path', 'List<String>', catchAll: true)],
    );
    const root = RouteInfo<Object?>(
      type: int,
      path: '/*all?',
      folder: '',
      segments: [RouteParam('all', 'List<String>', catchAll: true)],
    );
    final byPath = {
      for (final r in [docs, files, root, _all.first]) r.path: r,
    };

    test('finds a route by its path, and an optional catch-all without it', () {
      expect(lookupRoute(byPath, '/products/:id'), _all.first);
      expect(lookupRoute(byPath, '/docs/*rest'), docs);
      expect(lookupRoute(byPath, '/files/*path'), files);
      expect(lookupRoute(byPath, '/files'), files);
      expect(lookupRoute(byPath, '/'), root);
      // The path above a required catch-all is not that route.
      expect(lookupRoute(byPath, '/docs'), isNull);
      expect(lookupRoute(byPath, '/nope'), isNull);
      expect(lookupRoute(byPath, null), isNull);
    });
  });

  group('restoration ids', () {
    test('Transitions give their pages the key as restoration id', () {
      const key = ValueKey('/products/:id');
      final pages = [
        Transitions.fade(key, const SizedBox()),
        Transitions.slide(key, const SizedBox()),
        Transitions.none(key, const SizedBox()),
        Transitions.material(key, const SizedBox()),
        Transitions.cupertino(key, const SizedBox()),
        Transitions.dialog(key, const SizedBox()),
        Transitions.sheet(key, const SizedBox()),
        Transitions.fullscreenDialog(key, const SizedBox()),
      ];
      for (final p in pages) {
        expect(p.restorationId, '/products/:id', reason: '${p.runtimeType}');
      }
      // A key that isn't go_router's ValueKey<String> has no id to give.
      expect(
        Transitions.none(UniqueKey(), const SizedBox()).restorationId,
        isNull,
      );
    });

    testWidgets('layoutPage is a Material page with the given id', (
      tester,
    ) async {
      late Page<void> page;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) {
              page = layoutPage(context, state, 'layout:/', const SizedBox());
              return const SizedBox();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      expect(page, isA<MaterialPage<void>>());
      expect(page.restorationId, 'layout:/');
      expect(page.key, const ValueKey('layout:/'));
    });

    testWidgets('layoutPage is a Cupertino page in a CupertinoApp', (
      tester,
    ) async {
      late Page<void> page;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) {
              page = layoutPage(context, state, 'layout:/', const SizedBox());
              return const SizedBox();
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(CupertinoApp.router(routerConfig: router));
      expect(page, isA<CupertinoPage<void>>());
      expect(page.restorationId, 'layout:/');
    });
  });
}
