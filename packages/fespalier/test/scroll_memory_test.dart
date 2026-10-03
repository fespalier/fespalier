// `RouteScrollMemory`, which `scroll_restoration: true` puts around every page: the page's
// `PageStorage` bucket is kept per history entry and given back only when the browser brings
// that entry back. A `go` starts at the top; a scrollable without a `PageStorageKey` is never
// restored. The router here is what the generator writes with the key on.
import 'dart:async' show unawaited;

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page with a list under a `PageStorageKey` named `<name>-a`, and a second one beside it
/// (`<name>-b`) when [second] is set.
class ListPage extends StatelessWidget {
  const ListPage(this.name, {super.key, this.second = false});

  final String name;
  final bool second;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: _list(PageStorageKey<String>('$name-a'), 'a')),
      if (second)
        Expanded(child: _list(PageStorageKey<String>('$name-b'), 'b')),
    ],
  );

  Widget _list(Key key, String tag) => ListView.builder(
    key: key,
    itemCount: 100,
    itemExtent: 50,
    itemBuilder: (_, i) => Text('$name $tag $i'),
  );
}

/// A list whose scrollable has no `PageStorageKey` (a plain `ValueKey`, which Flutter does
/// not store anything for).
class UnkeyedPage extends StatelessWidget {
  const UnkeyedPage({super.key});

  @override
  Widget build(BuildContext context) => ListView.builder(
    key: const ValueKey<String>('unkeyed'),
    itemCount: 100,
    itemExtent: 50,
    itemBuilder: (_, i) => Text('unkeyed $i'),
  );
}

/// A page that shows a loading view for 100 ms, and then its list (what `loading.dart` does for
/// a page with a `data.dart`).
class LatePage extends StatefulWidget {
  const LatePage({super.key});

  @override
  State<LatePage> createState() => _LatePageState();
}

class _LatePageState extends State<LatePage> {
  var ready = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => ready = true);
    });
  }

  @override
  Widget build(BuildContext context) =>
      ready ? const ListPage('late') : const Text('loading');
}

/// The routes `fsp gen` writes with `scroll_restoration: true`: each page's view inside a
/// `RouteScrollMemory`.
GoRouter makeRouter(
  String initial, {
  List<String> extra = const [],
  void Function(GoRouterState state)? onState,
}) {
  Widget page(GoRouterState state, Widget child) {
    onState?.call(state);
    return RouteScrollMemory(state: state, child: child);
  }

  return GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/a',
        builder: (_, state) => page(state, const ListPage('a')),
      ),
      GoRoute(
        path: '/b',
        builder: (_, state) => page(state, const ListPage('b')),
      ),
      GoRoute(
        path: '/two',
        builder: (_, state) => page(state, const ListPage('two', second: true)),
      ),
      GoRoute(
        path: '/late',
        builder: (_, state) => page(state, const LatePage()),
      ),
      GoRoute(
        path: '/unkeyed',
        builder: (_, state) => page(state, const UnkeyedPage()),
      ),
      GoRoute(
        path: '/search',
        builder: (_, state) =>
            page(state, ListPage('search-${state.uri.queryParameters['q']}')),
      ),
      // The same page for every id: go_router keeps it mounted from `/c/1` to `/c/2`.
      GoRoute(
        path: '/c/:id',
        builder: (_, state) => page(state, const ListPage('c')),
      ),
      for (final path in extra)
        GoRoute(
          path: '/$path',
          builder: (_, state) => page(state, ListPage(path)),
        ),
    ],
  );
}

/// The browser's history, as far as the app can tell: what it reported to the platform for
/// each location (`routeInformationUpdated`), which is what the browser keeps for the entry
/// and hands back with back and forward.
class Browser {
  Browser(WidgetTester tester) : _tester = tester {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        if (call.method == 'routeInformationUpdated') {
          final args = call.arguments as Map<Object?, Object?>;
          entries.add((uri: args['uri']! as String, state: args['state']));
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        null,
      ),
    );
  }

  final WidgetTester _tester;

  /// What the app reported, oldest first.
  final List<({String uri, Object? state})> entries = [];

  /// The back or forward button: the engine tells the app the location of the entry it moved
  /// to, with the state the app saved for it.
  Future<void> goesTo(String location) async {
    final saved = entries.lastWhere((e) => e.uri == location);
    const codec = JSONMethodCodec();
    await _tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      codec.encodeMethodCall(
        MethodCall('pushRouteInformation', {
          'location': saved.uri,
          'state': saved.state,
        }),
      ),
      (_) {},
    );
    await _tester.pumpAndSettle();
  }
}

Future<(GoRouter, Browser)> boot(
  WidgetTester tester,
  String location, {
  List<String> extra = const [],
}) async {
  final browser = Browser(tester);
  final router = makeRouter(location, extra: extra);
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return (router, browser);
}

/// The list with the key named [key] (a `PageStorageKey` is a `ValueKey`).
Finder list(String key) => find.byWidgetPredicate(
  (w) =>
      w is ListView &&
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value == key,
);

/// The scroll offset of the list under [key].
double offset(WidgetTester tester, String key) => tester
    .state<ScrollableState>(
      find.descendant(of: list(key), matching: find.byType(Scrollable)),
    )
    .position
    .pixels;

/// Drags the list under [key] up by [by] logical pixels and lets it settle.
Future<double> scrollBy(WidgetTester tester, String key, double by) async {
  await tester.drag(list(key), Offset(0, -by));
  await tester.pumpAndSettle();
  return offset(tester, key);
}

Future<void> go(WidgetTester tester, GoRouter router, String location) async {
  router.go(location);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the browser bringing an entry back restores its scroll offset', (
    tester,
  ) async {
    final (router, browser) = await boot(tester, '/a');
    final scrolled = await scrollBy(tester, 'a-a', 600);
    expect(scrolled, greaterThan(0));

    await go(tester, router, '/b');
    expect(find.text('b a 0'), findsOneWidget);
    await browser.goesTo('/a');

    expect(find.text('a a 0'), findsNothing);
    expect(offset(tester, 'a-a'), scrolled);
  });

  testWidgets('forward restores too', (tester) async {
    final (router, browser) = await boot(tester, '/a');
    await go(tester, router, '/b');
    final scrolled = await scrollBy(tester, 'b-a', 400);

    await browser.goesTo('/a');
    expect(offset(tester, 'a-a'), 0);
    await browser.goesTo('/b');
    expect(offset(tester, 'b-a'), scrolled);
  });

  testWidgets('a go to a page that was scrolled starts at the top', (
    tester,
  ) async {
    final (router, _) = await boot(tester, '/a');
    await scrollBy(tester, 'a-a', 600);

    await go(tester, router, '/b');
    await go(tester, router, '/a');
    expect(find.text('a a 0'), findsOneWidget);
    expect(offset(tester, 'a-a'), 0);
  });

  testWidgets('a go over a remembered entry replaces what it kept', (
    tester,
  ) async {
    final (router, browser) = await boot(tester, '/a');
    await scrollBy(tester, 'a-a', 600);
    await go(tester, router, '/b');
    await go(tester, router, '/a');
    final fresh = await scrollBy(tester, 'a-a', 200);

    await go(tester, router, '/b');
    await browser.goesTo('/a');
    expect(offset(tester, 'a-a'), fresh);
  });

  testWidgets('a push starts the new page at the top', (tester) async {
    final (router, _) = await boot(tester, '/b');
    expect(await scrollBy(tester, 'b-a', 600), greaterThan(0));
    await go(tester, router, '/a');

    unawaited(router.push<void>('/b'));
    await tester.pumpAndSettle();
    expect(offset(tester, 'b-a'), 0);
  });

  testWidgets('two lists keep their own offsets', (tester) async {
    final (router, browser) = await boot(tester, '/two');
    final first = await scrollBy(tester, 'two-a', 600);
    final second = await scrollBy(tester, 'two-b', 250);
    expect(first, isNot(second));

    await go(tester, router, '/b');
    await browser.goesTo('/two');
    expect(offset(tester, 'two-a'), first);
    expect(offset(tester, 'two-b'), second);
  });

  testWidgets('a list without a PageStorageKey is not restored', (
    tester,
  ) async {
    final (router, browser) = await boot(tester, '/unkeyed');
    final scrolled = await scrollBy(tester, 'unkeyed', 600);
    expect(scrolled, greaterThan(0));

    await go(tester, router, '/b');
    await browser.goesTo('/unkeyed');
    expect(offset(tester, 'unkeyed'), 0);
  });

  testWidgets('a list that appears after a loading view is restored then', (
    tester,
  ) async {
    final (router, browser) = await boot(tester, '/late');
    await tester.pump(const Duration(milliseconds: 200));
    final scrolled = await scrollBy(tester, 'late-a', 500);
    expect(scrolled, greaterThan(0));
    await go(tester, router, '/b');

    await browser.goesTo('/late');
    await tester.pump(const Duration(milliseconds: 200));
    expect(offset(tester, 'late-a'), scrolled);
  });

  testWidgets('the query tells two entries of one page apart', (tester) async {
    final (router, browser) = await boot(tester, '/search?q=x');
    final x = await scrollBy(tester, 'search-x-a', 500);
    await go(tester, router, '/b');
    await go(tester, router, '/search?q=y');
    final y = await scrollBy(tester, 'search-y-a', 300);
    await go(tester, router, '/b');

    await browser.goesTo('/search?q=x');
    expect(offset(tester, 'search-x-a'), x);
    await go(tester, router, '/b');
    await browser.goesTo('/search?q=y');
    expect(offset(tester, 'search-y-a'), y);
  });

  testWidgets('a page that stays mounted keeps its bucket under the new URL', (
    tester,
  ) async {
    final (router, browser) = await boot(tester, '/c/1');
    await scrollBy(tester, 'c-a', 300);
    // Same page, new segment: the list is live, not restored, and its offset stays.
    await go(tester, router, '/c/2');
    final scrolled = await scrollBy(tester, 'c-a', 200);

    await go(tester, router, '/b');
    await browser.goesTo('/c/2');
    expect(offset(tester, 'c-a'), scrolled);
  });

  testWidgets('a router remembers 64 entries, the oldest forgotten first', (
    tester,
  ) async {
    final names = [for (var i = 0; i < 65; i++) 'p$i'];
    final (router, browser) = await boot(tester, '/p0', extra: names);
    expect(await scrollBy(tester, 'p0-a', 400), greaterThan(0));
    late double kept;
    for (final name in names.skip(1)) {
      await go(tester, router, '/$name');
      if (name == 'p2') kept = await scrollBy(tester, 'p2-a', 300);
    }
    await go(tester, router, '/b');

    // 66 pages were built (p0 to p64 and b): p0 and p1 are the two forgotten, p2 is the
    // oldest one left.
    await browser.goesTo('/p2');
    expect(offset(tester, 'p2-a'), kept);
    await browser.goesTo('/p0');
    expect(offset(tester, 'p0-a'), 0);
  });

  testWidgets('each router has a memory of its own', (tester) async {
    final (router, browser) = await boot(tester, '/a');
    final scrolled = await scrollBy(tester, 'a-a', 600);
    await go(tester, router, '/b');
    final saved = browser.entries.lastWhere((e) => e.uri == '/a');

    // A second router, in a second app: the browser brings `/a` back to it, but this router
    // never showed it, so there is nothing to give back.
    final other = makeRouter('/b');
    addTearDown(other.dispose);
    await tester.pumpWidget(
      MaterialApp.router(key: UniqueKey(), routerConfig: other),
    );
    await tester.pumpAndSettle();
    browser.entries.add((uri: '/a', state: saved.state));
    await browser.goesTo('/a');
    expect(find.text('a a 0'), findsOneWidget);
    expect(scrolled, greaterThan(0));
    expect(offset(tester, 'a-a'), 0);
  });

  testWidgets('a page built outside a router still builds', (tester) async {
    late GoRouterState captured;
    final router = makeRouter('/a', onState: (s) => captured = s);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      MaterialApp(
        home: RouteScrollMemory(state: captured, child: const ListPage('free')),
      ),
    );
    expect(find.text('free a 0'), findsOneWidget);
  });

  testWidgets('the key is the matched location, and the query for the leaf', (
    tester,
  ) async {
    final states = <String, GoRouterState>{};
    final router = GoRouter(
      initialLocation: '/p/1?x=2',
      routes: [
        GoRoute(
          path: '/p',
          builder: (_, state) {
            states['parent'] = state;
            return const Text('parent');
          },
          routes: [
            GoRoute(
              path: '1',
              builder: (_, state) {
                states['leaf'] = state;
                return const Text('leaf');
              },
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // The page below another keeps its own location; the top one adds the query.
    expect(scrollKeyOf(states['parent']!), '/p');
    expect(scrollKeyOf(states['leaf']!), '/p/1?x=2');
  });
}
