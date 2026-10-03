// What `fsp test` runs for each route (since 0.8.0): `smokeTestRoute` waits, on the fake clock,
// until the page is on screen, and says where the router is when it never comes.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A list that answers after 700 ms and an item that answers after 500 ms, as the shop's fake
/// API does: the test has to wait both out on the fake clock.
final listProvider = FutureProvider.autoDispose<List<int>>((ref) async {
  await Future<void>.delayed(const Duration(milliseconds: 700));
  return const [1, 2];
});

final itemProvider = FutureProvider.autoDispose.family<int, int>((
  ref,
  id,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 500));
  return id;
});

final signedInProvider = Provider<bool>((ref) => false);

/// A page whose widget is a `Semantics(identifier: 'route:<pattern>')`, as `semantics_ids: true`
/// makes every page.
Widget route(String pattern, Widget child) =>
    Semantics(identifier: 'route:$pattern', child: child);

class ItemsPage extends ConsumerWidget {
  const ItemsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(listProvider)
      .when(
        data: (items) => route(
          '/items',
          Column(children: [for (final i in items) Text('item $i')]),
        ),
        loading: () => const Text('loading'),
        error: (e, _) => Text('$e'),
      );
}

class ItemPage extends ConsumerWidget {
  const ItemPage(this.id, {super.key});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(itemProvider(id))
      .when(
        data: (i) => route('/items/:id', Text('item #$i')),
        loading: () => const Text('loading'),
        error: (e, _) => Text('$e'),
      );
}

GoRouter router(String location) => GoRouter(
  initialLocation: location,
  redirect: (context, state) {
    if (state.uri.path != '/sign-in' &&
        !ProviderScope.containerOf(
          context,
          listen: false,
        ).read(signedInProvider)) {
      // Only `/items` is guarded.
      if (state.uri.path == '/items') return '/sign-in';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) => route('/', const Text('home')),
      routes: [
        GoRoute(
          path: 'items',
          builder: (_, _) => const ItemsPage(),
          routes: [
            GoRoute(
              path: ':id',
              builder: (_, s) => ItemPage(int.parse(s.pathParameters['id']!)),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/sign-in',
      builder: (_, _) => route('/sign-in', const Text('sign in')),
    ),
  ],
);

void main() {
  testWidgets('a guard gets past an override, and a 700 ms list is waited out', (
    tester,
  ) async {
    await smokeTestRoute(
      tester,
      '/items',
      router('/items'),
      overrides: [signedInProvider.overrideWithValue(true)],
    );
    // Nothing is left running, so the test ends without "A Timer is still pending".
  });

  testWidgets('a page with a slower item under a faster one passes', (
    tester,
  ) async {
    await smokeTestRoute(
      tester,
      '/items/:id',
      router('/items/2'),
      overrides: [signedInProvider.overrideWithValue(true)],
    );
  });

  testWidgets('a guard that redirects fails the test, naming where it ended', (
    tester,
  ) async {
    TestFailure? failure;
    try {
      await smokeTestRoute(
        tester,
        '/items',
        router('/items'),
        timeout: const Duration(seconds: 2),
      );
    } on TestFailure catch (e) {
      failure = e;
    }
    expect(
      failure?.message,
      allOf(
        contains('The page of /items is not on screen after 2000 ms'),
        contains('the router is at /sign-in'),
      ),
    );
  });

  testWidgets('page: finds the page by something else than its identifier', (
    tester,
  ) async {
    await smokeTestRoute(
      tester,
      '/items',
      router('/items'),
      page: find.byType(ItemsPage),
      overrides: [signedInProvider.overrideWithValue(true)],
    );
  });

  testWidgets('findRoutePage finds a page and skips one off screen', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => route('/', const Text('home')),
          routes: [
            GoRoute(
              path: 'next',
              builder: (_, _) => route('/next', const Text('next')),
            ),
          ],
        ),
      ],
    );
    await pumpRouter(tester, router);
    expect(findRoutePage('/'), findsOneWidget);
    expect(findRoutePage('/next'), findsNothing);
    unawaited(router.push('/next'));
    await tester.pumpAndSettle();
    expect(findRoutePage('/next'), findsOneWidget);
    // The page underneath is off screen once the new one covers it.
    expect(findRoutePage('/'), findsNothing);
  });

  testWidgets('pumpRouter(app:) builds the app around the router', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      router('/sign-in'),
      app: (r) => MaterialApp.router(routerConfig: r, title: 'x'),
    );
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'x');
    expect(find.text('sign in'), findsOneWidget);
  });

  testWidgets('smokeTestRoute(app:) uses it too', (tester) async {
    var built = 0;
    await smokeTestRoute(
      tester,
      '/sign-in',
      router('/sign-in'),
      app: (r) {
        built++;
        return MaterialApp.router(routerConfig: r);
      },
    );
    expect(built, greaterThan(0));
  });
}
