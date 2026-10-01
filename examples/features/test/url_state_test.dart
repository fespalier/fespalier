// The URL as typed state: `XRoute.of(context)` parses the location the widget belongs to
// with the parsers `AppRoutes.match` uses, so the case setting, a localized spelling, an
// enum, a list and a catch-all all read as they do for the page; `copyWith` changes some
// of the parameters and keeps the rest.
import 'package:features/app.g.dart';
import 'package:features/app/search/page.dart';
import 'package:features/app/shop/\$category/page.dart' show Sort;
import 'package:features/models/category.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

Future<void> boot(WidgetTester tester, String location) async {
  await tester.pumpWidget(
    ProviderScope(
      // go_router 17 detects flutter's MaterialApp, go_router 18 material_ui's;
      // nesting both gives Material pages and error screens on either.
      child: MaterialApp(
        home: mui.MaterialApp.router(
          routerConfig: AppRoutes.router(initialLocation: location),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The context of the widget that shows [text].
BuildContext at(WidgetTester tester, String text) =>
    tester.element(find.text(text));

void main() {
  group('of', () {
    testWidgets('reads a query with a string, an int and a list', (
      tester,
    ) async {
      await boot(tester, '/search?q=ap&page=2&tags=red&tags=sweet');
      final route = SearchRoute.of(tester.element(find.byType(SearchPage)));
      expect(route.q, 'ap');
      expect(route.page, 2);
      expect(route.tags, ['red', 'sweet']);
      expect(route.location, '/search?q=ap&page=2&tags=red&tags=sweet');
    });

    testWidgets('reads an enum segment and an enum query in any case', (
      tester,
    ) async {
      // This app matches paths in any case (`case_sensitive: false`).
      await boot(tester, '/SHOP/Hats?sort=NAME');
      final route = CategoryShopRoute.of(at(tester, 'sorted by name'));
      expect(route.category, Category.hats);
      expect(route.location, '/shop/hats?sort=name');
    });

    testWidgets('a catch-all keeps its parts, an optional one may be empty', (
      tester,
    ) async {
      await boot(tester, '/docs/guide/set%20up');
      expect(DocsRoute.of(at(tester, 'Doc guide > set up')).rest, [
        'guide',
        'set up',
      ]);
      await boot(tester, '/files');
      expect(FilesRoute.of(at(tester, 'Files root')).path, isEmpty);
      await boot(tester, '/files/a/b');
      expect(FilesRoute.of(at(tester, 'File a/b')).path, ['a', 'b']);
    });

    testWidgets('reads a localized spelling as the route it is', (
      tester,
    ) async {
      for (final path in ['/help/routing', '/aide/routing', '/HILFE/routing']) {
        await boot(tester, path);
        final context = at(tester, 'Help topic routing');
        expect(HelpTopicRoute.of(context).topic, 'routing', reason: path);
        // The route is a value: the spelling is chosen where it is used.
        expect(HelpTopicRoute.of(context).location, '/help/routing');
        expect(
          HelpTopicRoute.of(context).locationFor('fr'),
          '/aide/routing',
        );
      }
    });

    testWidgets('a copy keeps the route and picks the spelling to go to', (
      tester,
    ) async {
      await boot(tester, '/hilfe/routing');
      final context = at(tester, 'Help topic routing');
      HelpTopicRoute.of(context).copyWith(topic: 'testing').go(
            context,
            locale: 'de',
          );
      await tester.pumpAndSettle();
      expect(find.text('Help topic testing'), findsOneWidget);
      expect(
        GoRouter.of(at(tester, 'Help topic testing'))
            .routeInformationProvider
            .value
            .uri
            .toString(),
        '/hilfe/testing',
      );
    });

    testWidgets('a page under another one reads its own route', (tester) async {
      // /help/:topic/examples is built over /help/:topic, which is built over /help.
      await boot(tester, '/aide/routing/exemples');
      expect(find.text('Examples of routing'), findsOneWidget);
      final topic = HelpTopicRoute.of(
        tester.element(find.text('Help topic routing', skipOffstage: false)),
      );
      expect(topic.topic, 'routing');
      final examples = tester.element(find.text('Examples of routing'));
      expect(HelpExamplesRoute.of(examples).topic, 'routing');
      expect(HelpTopicRoute.maybeOf(examples), isNull);
    });

    testWidgets('a pushed page reads its own, the page below its own', (
      tester,
    ) async {
      await boot(tester, '/');
      final home = tester.element(find.text('Home'));
      const SearchRoute(q: 'ap').push<void>(home);
      await tester.pumpAndSettle();
      final search = tester.element(find.byType(SearchPage));
      expect(SearchRoute.of(search).q, 'ap');
      expect(HomeRoute.maybeOf(search), isNull);
      // The page below still reads its own location, not the pushed one.
      final below = tester.element(find.text('Home', skipOffstage: false));
      expect(HomeRoute.maybeOf(below), isNotNull);
      expect(SearchRoute.maybeOf(below), isNull);
    });
  });

  group('copyWith', () {
    test('keeps what is left out and clears what is null', () {
      const route = SearchRoute(q: 'ap', page: 2, tags: ['red']);
      expect(route.copyWith().location, route.location);
      expect(route.copyWith(page: 3).location, '/search?q=ap&page=3&tags=red');
      expect(route.copyWith(page: null).location, '/search?q=ap&tags=red');
      expect(route.copyWith(q: null, page: null).location, '/search?tags=red');
      // A list can't be null: an empty one clears it.
      expect(route.copyWith(tags: const []).location, '/search?q=ap&page=2');
    });

    test('an enum segment and an enum query', () {
      const route = CategoryShopRoute(category: Category.hats, sort: Sort.name);
      expect(route.copyWith(category: Category.shoes).location,
          '/shop/shoes?sort=name');
      expect(route.copyWith(sort: null).location, '/shop/hats');
    });

    test('a catch-all is replaced as a whole', () {
      const route = DocsRoute(rest: ['a', 'b']);
      expect(route.copyWith(rest: ['c']).location, '/docs/c');
    });

    test('a null that is passed is not a missing argument', () {
      const route = SearchRoute(q: 'ap');
      final cleared = route.copyWith(q: null);
      expect(cleared.q, isNull);
      expect(route.copyWith(page: 1).q, 'ap');
    });
  });
}
