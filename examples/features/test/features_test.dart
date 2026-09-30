import 'package:features/app.g.dart';
import 'package:features/app/search/data.dart' as search_data;
import 'package:features/app/shops/\$shop/items/\$id/data.dart' as item_data;
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:flutter_test/flutter_test.dart';

/// The app's retry policy in tests: none, so a failing data() leaves no timer behind.
Duration? noRetry(int retryCount, Object error) => null;

Future<void> boot(
  WidgetTester tester,
  String location, {
  Duration? Function(int retryCount, Object error)? retry = noRetry,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      retry: retry,
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

  group('retries: the app decides (data_retry: inherit)', () {
    setUp(() {
      item_data.itemFetches = 0;
      item_data.flakyRuns = 0;
    });

    /// Retry twice, 100 ms apart, like a bounded policy.
    Duration? twice(int retryCount, Object error) =>
        retryCount < 2 ? const Duration(milliseconds: 100) : null;

    testWidgets('a container policy is honoured: retries, then settles',
        (tester) async {
      await boot(tester, '/shops/acme/items/0', retry: twice);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Failed: Exception: no item 0'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      // The generated provider ran three times: once, plus the two retries
      // the policy allows. It doesn't override the app's policy with its own.
      expect(item_data.itemFetches, 3);
      expect(find.textContaining('Failed: Exception: no item 0'),
          findsOneWidget);
      await tester.pump(const Duration(minutes: 2));
      expect(item_data.itemFetches, 3);
    });

    testWidgets('Riverpod default policy applies when the app has none',
        (tester) async {
      await boot(tester, '/shops/acme/items/0', retry: null);
      await tester.pump(const Duration(seconds: 2));
      expect(item_data.itemFetches, greaterThan(2));
      // A retry timer is pending; end the test by unmounting the tree.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('error.dart shows at once and stays through the retries',
        (tester) async {
      // Fails twice (runs 1 and 2), then yields.
      await boot(tester, '/shops/acme/items/13', retry: twice);
      expect(find.byType(DefaultLoading), findsOneWidget);
      var errors = 0;
      for (var ms = 10; ms <= 400; ms += 10) {
        await tester.pump(const Duration(milliseconds: 10));
        expect(find.byType(DefaultLoading), findsNothing, reason: 'at $ms ms');
        if (find.textContaining('Failed: Exception: flaky').evaluate().isNotEmpty) {
          errors++;
        }
      }
      expect(item_data.flakyRuns, 3);
      expect(errors, greaterThan(15));
      expect(find.text('Item acme #13'), findsOneWidget);
      expect(find.textContaining('Failed:'), findsNothing);
    });

    testWidgets("error.dart's retry callback still runs data.dart again",
        (tester) async {
      await boot(tester, '/shops/acme/items/0');
      await tester.pump(const Duration(milliseconds: 50));
      expect(item_data.itemFetches, 1);
      expect(find.textContaining('Failed: Exception: no item 0'),
          findsOneWidget);

      // Nothing runs behind the scenes; retry is what runs it again.
      await tester.pump(const Duration(seconds: 60));
      expect(item_data.itemFetches, 1);
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      // The error stays up while it runs.
      expect(find.byType(DefaultLoading), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Failed: Exception: no item 0'),
          findsOneWidget);
      expect(item_data.itemFetches, 2);
    });
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
    await boot(tester, '/search?q=ap&tags=sweet');
    await tester.pump();
    expect(find.text('ap, page 1: apple, apricot'), findsOneWidget);
    expect(find.text('tags: sweet'), findsOneWidget);

    // Typed navigation carries the query; a new `page` is a new data key.
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('ap, page 2: '), findsOneWidget);
    expect(find.text('tags: sweet'), findsOneWidget);
  });

  testWidgets('a List query parameter is part of the data key', (tester) async {
    search_data.searchFetches = 0;
    await boot(tester, '/search?tags=red');
    await tester.pump();
    expect(find.text('everything, page 1: apple, cherry'), findsOneWidget);

    // Same route, another list: another provider, another result.
    final context = tester.element(find.text('Next'));
    const SearchRoute(tags: ['red', 'sweet']).go(context);
    await tester.pumpAndSettle();
    expect(find.text('everything, page 1: apple'), findsOneWidget);
    expect(search_data.searchFetches, 2);
  });

  test('lists with the same elements are one data key', () async {
    search_data.searchFetches = 0;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // A new list each time, as a rebuilt page makes; the provider is
    // autoDispose, so hold it the way a mounted page does.
    ({String? q, int? page, QueryList<String> tags}) key(List<String> tags) =>
        (q: null, page: null, tags: QueryList(tags));
    final sub = container.listen(SearchRoute.data(key(['red'])), (_, __) {});
    addTearDown(sub.close);
    expect(await container.read(SearchRoute.data(key(['red'])).future),
        ['apple', 'cherry']);
    expect(await container.read(SearchRoute.data(key(['red'])).future),
        ['apple', 'cherry']);
    expect(search_data.searchFetches, 1);
    expect(await container.read(SearchRoute.data(key(['sweet'])).future),
        ['apple', 'apricot']);
    expect(search_data.searchFetches, 2);
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

  group('dialog, sheet and full-screen routes', () {
    late GoRouter router;

    Future<void> bootPhotos(WidgetTester tester, String location) async {
      router = AppRoutes.router(initialLocation: location);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: mui.MaterialApp.router(
              routerConfig: router,
              // Dialogs and sheets read flutter's MaterialLocalizations.
              localizationsDelegates: const [
                DefaultMaterialLocalizations.delegate,
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String location() =>
        router.routerDelegate.currentConfiguration.last.matchedLocation;

    testWidgets('a route with Transitions.dialog opens over the previous page',
        (tester) async {
      await bootPhotos(tester, '/photos');
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('Open photo 7'));
      await tester.pumpAndSettle();
      expect(location(), '/photos/7');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Photo 7'), findsOneWidget);
      // The page below is still there, behind the barrier.
      expect(find.text('Photos'), findsOneWidget);
      expect(ModalRoute.of(tester.element(find.text('Photo 7'))),
          isA<DialogRoute<void>>());

      // context.pop() in the dialog returns to the page.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(location(), '/photos');
      expect(find.text('Photos'), findsOneWidget);
    });

    testWidgets('the barrier and the back button pop a dialog route',
        (tester) async {
      await bootPhotos(tester, '/photos');
      await tester.tap(find.text('Open photo 7'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(location(), '/photos');

      await tester.tap(find.text('Open photo 7'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(location(), '/photos');
    });

    testWidgets('a deep link opens the dialog over its parent page',
        (tester) async {
      await bootPhotos(tester, '/photos/7');
      expect(find.text('Photo 7'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(location(), '/photos');
      expect(find.text('Photos'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      expect(const PhotoRoute(id: 7).location, '/photos/7');
    });

    testWidgets('Transitions.sheet opens a modal bottom sheet',
        (tester) async {
      await bootPhotos(tester, '/photos');
      await tester.tap(find.text('Sort'));
      await tester.pumpAndSettle();
      expect(location(), '/photos/sort');
      expect(find.text('Sort photos by'), findsOneWidget);
      expect(find.text('Photos'), findsOneWidget);
      expect(ModalRoute.of(tester.element(find.text('Sort photos by'))),
          isA<ModalBottomSheetRoute<void>>());

      await tester.tap(find.text('Newest'));
      await tester.pumpAndSettle();
      expect(find.text('Sort photos by'), findsNothing);
      expect(location(), '/photos');

      // Also as a deep link, and dismissed by the barrier.
      await bootPhotos(tester, '/photos/sort');
      expect(find.text('Sort photos by'), findsOneWidget);
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(find.text('Sort photos by'), findsNothing);
      expect(location(), '/photos');
    });

    testWidgets('Transitions.fullscreenDialog slides up with a close button',
        (tester) async {
      await bootPhotos(tester, '/photos');
      await tester.tap(find.text('Upload'));
      await tester.pumpAndSettle();
      expect(location(), '/photos/upload');
      final route = ModalRoute.of(tester.element(find.text('Pick a file')))!;
      expect(route.settings, isA<MaterialPage<void>>());
      expect(route.fullscreenDialog, isTrue);

      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      expect(location(), '/photos');
      expect(find.text('Pick a file'), findsNothing);
    });
  });
}
