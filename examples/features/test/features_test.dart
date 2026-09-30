import 'package:features/app.g.dart';
import 'package:features/app/shops/\$shop/items/\$id/data.dart' as item_data;
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:flutter_test/flutter_test.dart';

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
  await tester.pump();
}

void main() {
  testWidgets('layouts and pages get the segments they ask for',
      (tester) async {
    await boot(tester, '/shops/acme');
    expect(find.text('Shop: acme'), findsOneWidget);
    expect(find.text('Welcome to acme'), findsOneWidget);
  });

  testWidgets('guards get segments', (tester) async {
    await boot(tester, '/shops/closed');
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('data keyed by two segments, bound to the page by type',
      (tester) async {
    await boot(tester, '/shops/acme/items/7');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Shop: acme'), findsOneWidget);
    expect(find.text('Item acme #7'), findsOneWidget);
    expect(
        const ItemRoute(shop: 'a b', id: 7).location, '/shops/a%20b/items/7');
  });

  testWidgets('error.dart bound by type; retry re-runs data.dart',
      (tester) async {
    await boot(tester, '/shops/acme/items/0');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Failed: Exception: no item 0'), findsOneWidget);
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Failed:'), findsOneWidget);
  });

  testWidgets('a failing data() shows error.dart at once: no Riverpod retries',
      (tester) async {
    // The harness has no `ProviderScope(retry: ...)`. Riverpod 3 would retry a
    // provider that throws an Exception ~10 times with backoff (error view after
    // ~38 s; it never retries an Error such as StateError); the
    // providers fespalier generates opt out, so error.dart is the retry UX.
    item_data.itemFetches = 0;
    await boot(tester, '/shops/acme/items/0');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Failed: Exception: no item 0'), findsOneWidget);
    expect(item_data.itemFetches, 1);

    // Nothing is scheduled behind the scenes (an armed retry timer would also
    // fail this test when it ends).
    await tester.pump(const Duration(seconds: 60));
    expect(find.textContaining('Failed:'), findsOneWidget);
    expect(item_data.itemFetches, 1);

    // Retry is what runs it again.
    await tester.tap(find.byType(TextButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Failed: Exception: no item 0'), findsOneWidget);
    expect(item_data.itemFetches, 2);
  });

  testWidgets('an int segment that does not parse is not found',
      (tester) async {
    await boot(tester, '/shops/acme/items/x');
    expect(find.text('Nothing at /shops/acme/items/x'), findsOneWidget);
  });

  testWidgets('a user-written AsyncNotifierProvider, exposed on the route',
      (tester) async {
    await boot(tester, '/counter');
    await tester.pump();
    expect(find.text('Count 0'), findsOneWidget);
    await tester.tap(find.text('Count 0'));
    await tester.pump();
    expect(find.text('Count 1'), findsOneWidget);
  });

  testWidgets('Stream data', (tester) async {
    await boot(tester, '/ticks');
    await tester.pump();
    expect(find.text('Tick 42'), findsOneWidget);
  });

  testWidgets('query parameters reach the page and key data.dart',
      (tester) async {
    await boot(tester, '/search?q=ap&tags=red&tags=ripe');
    await tester.pump();
    expect(find.text('ap, page 1: apple, apricot'), findsOneWidget);
    expect(find.text('tags: red, ripe'), findsOneWidget);

    // Typed navigation carries the query; a new `page` is a new data key.
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('ap, page 2: '), findsOneWidget);
    expect(find.text('tags: red, ripe'), findsOneWidget);
  });

  testWidgets('absent or unparsable query parameters are null', (tester) async {
    await boot(tester, '/search?page=x');
    await tester.pump();
    expect(find.text('everything, page 1: apple, apricot'), findsOneWidget);
  });

  test('typed routes write the query', () {
    expect(const SearchRoute().location, '/search');
    expect(
      const SearchRoute(q: 'a b', page: 2, tags: ['x', 'y']).location,
      '/search?q=a+b&page=2&tags=x&tags=y',
    );
  });

  testWidgets('layouts get query parameters', (tester) async {
    await boot(tester, '/?banner=hello');
    expect(find.text('Banner: hello'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('(group) layouts wrap their routes, not their siblings',
      (tester) async {
    await boot(tester, '/profile');
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);

    await boot(tester, '/search');
    expect(find.text('Account'), findsNothing);
  });

  testWidgets('static routes win over a dynamic sibling', (tester) async {
    await boot(tester, '/settings');
    expect(find.text('Settings'), findsOneWidget);
    await boot(tester, '/counter');
    expect(find.textContaining('Page '), findsNothing);
    await boot(tester, '/anything');
    expect(find.text('Page anything'), findsOneWidget);
  });

  testWidgets('transition.dart picks the Page: nearest one wins',
      (tester) async {
    RouteSettings settings(String text) =>
        ModalRoute.of(tester.element(find.text(text)))!.settings;

    // (account)/transition.dart covers /profile.
    await boot(tester, '/profile');
    await tester.pumpAndSettle();
    expect(settings('Profile'), isA<CustomTransitionPage<void>>());

    // ticks/transition.dart is Transitions.none.
    await boot(tester, '/ticks');
    await tester.pumpAndSettle();
    expect(settings('Tick 42'), isA<NoTransitionPage<void>>());

    // Nothing closer to /search: the root transition.dart, Transitions.material.
    await boot(tester, '/search');
    await tester.pumpAndSettle();
    expect(settings('everything, page 1: apple, apricot'),
        isA<MaterialPage<void>>());
  });

  testWidgets('a route with a transition fades in', (tester) async {
    await boot(tester, '/');
    await tester.pumpAndSettle();

    const ProfileRoute().go(tester.element(find.text('Home')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The page's own fade is one of several FadeTransitions above the text.
    final opacities = tester
        .widgetList<FadeTransition>(
          find.ancestor(
            of: find.text('Profile'),
            matching: find.byType(FadeTransition),
          ),
        )
        .map((fade) => fade.opacity.value);
    expect(opacities.any((o) => o > 0 && o < 1), isTrue, reason: '$opacities');

    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsOneWidget);
  });

  test('groups leave no trace in typed locations', () {
    expect(const ProfileRoute().location, '/profile');
    expect(const SlugRoute(slug: 'x').location, '/x');
  });
}
