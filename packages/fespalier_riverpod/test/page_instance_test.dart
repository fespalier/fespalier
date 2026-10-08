// Providers per page instance, through a real go_router: the key is core's pageInstanceId, so
// the states follow the lifecycle the route scope has (a push is an instance, a query change is
// not, a remount is not, a pop ends one), and holdForPage keeps a state no widget watches.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_riverpod/fespalier_riverpod.dart';
import 'package:fespalier_riverpod/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What `lib/app/c/$id/route.dart` would generate, by hand.
final class CRoute extends TypedLocation {
  const CRoute(this.id);
  final int id;

  @override
  String get location => '/c/$id';

  static CRoute of(BuildContext context) =>
      CRoute(int.parse(GoRouterState.of(context).pathParameters['id']!));
}

int serials = 0;
int labels = 0;
int builds = 0;
int disposes = 0;

/// The state of a page: a serial number, so two states are told apart.
class Draft extends Notifier<int> {
  Draft(this.page);
  final PageInstance<CRoute> page;

  @override
  int build() {
    builds++;
    ref.onDispose(() => disposes++);
    return ++serials;
  }
}

final draft = pageNotifierProvider<Draft, int, CRoute>(Draft.new);

/// The same through the plain form, to see the route a key carries.
final label = pageProvider<String, CRoute>(
  (ref, page) => 'c${page.route.id}#${++labels}',
);

/// The instances the pages built, in order.
final List<PageInstance<CRoute>> seen = [];

/// The instances the scopes were made for, by the id of the scope.
final Map<String, PageInstance<CRoute>> scoped = {};

final List<RouteScope> scopes = [];

class ChatPage extends ConsumerWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = PageInstance.of(context, CRoute.of);
    seen.add(page);
    return Scaffold(
      body: Text('draft ${ref.watch(draft(page))} ${ref.watch(label(page))}'),
    );
  }
}

class HookPage extends HookConsumerWidget {
  const HookPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = usePageInstance(CRoute.of);
    seen.add(page);
    return Scaffold(body: Text('hook ${ref.watch(draft(page))}'));
  }
}

/// A page that watches nothing: only the scope's hold keeps its state.
class QuietPage extends StatelessWidget {
  const QuietPage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('quiet'));
}

Widget plain(String text) => Scaffold(body: Text(text));

List<RouteHooks> hooksAt(Uri uri) => [
  RouteHooks(
    'observe.dart',
    onEnter: (ref, scope) {
      scopes.add(scope);
      final segments = uri.pathSegments;
      if (segments.length != 2) return;
      final id = int.parse(segments[1]);
      final page = PageInstance.ofScope(scope, CRoute(id));
      scoped[scope.id] = page;
      // /t/:id holds its state; /u/:id does the same without holding.
      if (segments.first == 't') holdForPage(scope, draft(page));
    },
  ),
];

GoRouter router() {
  final r = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => plain('home')),
      GoRoute(path: '/x', builder: (_, _) => plain('x')),
      GoRoute(path: '/c/:id', builder: (_, _) => const ChatPage()),
      GoRoute(path: '/h/:id', builder: (_, _) => const HookPage()),
      GoRoute(path: '/u/:id', builder: (_, _) => const QuietPage()),
      GoRoute(
        path: '/r/:id',
        pageBuilder: (context, state) => remountPage(
          context,
          state,
          remountKey(state, Remount.onLocation, const ['id']),
          const ChatPage(),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/t',
                builder: (_, _) => plain('t'),
                routes: [
                  GoRoute(path: ':id', builder: (_, _) => const QuietPage()),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/b', builder: (_, _) => plain('b'))],
          ),
        ],
      ),
    ],
  );
  observeAttach(r, hooksAt);
  return r;
}

late ProviderContainer container;

Future<GoRouter> boot(WidgetTester tester) async {
  serials = 0;
  labels = 0;
  builds = 0;
  disposes = 0;
  seen.clear();
  scoped.clear();
  scopes.clear();
  final r = router();
  container = await pumpRouter(tester, r);
  return r;
}

/// Navigates, then lets Riverpod dispose what nothing listens to (it does so in a task it
/// schedules, not when the last listener goes).
Future<void> go(WidgetTester tester, GoRouter r, String location) async {
  r.go(location);
  await settle(tester);
}

Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() => container.pump());
}

void main() {
  group('PageInstance', () {
    test('is equal by id: the route is not part of it', () {
      const a = PageInstance('x#/c/1', CRoute(1));
      const b = PageInstance('x#/c/1', CRoute(2));
      const c = PageInstance('x#/c/2', CRoute(1));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.toString(), contains('x#/c/1'));
    });

    test('a TestPageInstance is a key like any other', () {
      const a = TestPageInstance(CRoute(1));
      const b = TestPageInstance(CRoute(1), id: 'second');
      expect(a.id, 'test');
      expect(a, const TestPageInstance(CRoute(1)));
      expect(a, isNot(b));
      expect(a, const PageInstance<CRoute>('test', CRoute(1)));

      final c = ProviderContainer();
      addTearDown(c.dispose);
      final keep = c.listen(draft(a), (_, _) {});
      final other = c.listen(draft(b), (_, _) {});
      addTearDown(keep.close);
      addTearDown(other.close);
      expect(keep.read(), isNot(other.read()));
      expect(c.read(draft(const TestPageInstance(CRoute(1)))), keep.read());
    });
  });

  testWidgets('a page pushed twice is two states', (tester) async {
    final r = await boot(tester);
    unawaited(r.push<void>('/c/1'));
    await tester.pumpAndSettle();
    unawaited(r.push<void>('/c/1'));
    await settle(tester);
    expect(seen.map((p) => p.id).toSet(), hasLength(2));
    // The scope's key is the page's key, for each pushed page.
    expect(scoped.keys.toSet(), seen.map((p) => p.id).toSet());
    for (final p in seen) {
      expect(scoped[p.id], p);
    }
    expect(find.textContaining('draft 2'), findsOneWidget);
    expect(find.textContaining('draft 1', skipOffstage: false), findsOneWidget);
    expect(builds, 2);
    // Both are still on the navigator, and both states are alive.
    expect(disposes, 0);
  });

  testWidgets('a query change is the same state', (tester) async {
    final r = await boot(tester);
    await go(tester, r, '/c/1');
    expect(find.textContaining('draft 1 c1#1'), findsOneWidget);
    await go(tester, r, '/c/1?q=2');
    expect(find.textContaining('draft 1 c1#1'), findsOneWidget);
    expect((builds, disposes), (1, 0));
    expect(seen.map((p) => p.id).toSet(), hasLength(1));
  });

  testWidgets('another segment value is another state, and the old one goes', (
    tester,
  ) async {
    final r = await boot(tester);
    await go(tester, r, '/c/1');
    await go(tester, r, '/c/2');
    expect(find.textContaining('draft 2 c2#'), findsOneWidget);
    expect((builds, disposes), (2, 1));
  });

  testWidgets('a remount of the page is the same state', (tester) async {
    final r = await boot(tester);
    await go(tester, r, '/r/1');
    final first = find.textContaining('draft 1');
    expect(first, findsOneWidget);
    final element = tester.element(find.byType(ChatPage));
    await go(tester, r, '/r/1?q=2');
    expect(
      tester.element(find.byType(ChatPage)),
      isNot(same(element)),
      reason: 'remount: onLocation rebuilt the page',
    );
    expect(find.textContaining('draft 1'), findsOneWidget);
    expect((builds, disposes), (1, 0));
    // A new segment value is a new instance for the remount too.
    await go(tester, r, '/r/2');
    expect(find.textContaining('draft 2'), findsOneWidget);
    expect((builds, disposes), (2, 1));
  });

  testWidgets('a pop disposes the state', (tester) async {
    final r = await boot(tester);
    unawaited(r.push<void>('/c/1'));
    await settle(tester);
    expect((builds, disposes), (1, 0));
    r.pop();
    await settle(tester);
    expect(find.text('home'), findsOneWidget);
    expect(disposes, 1);
  });

  testWidgets('the page and the scope give the same key', (tester) async {
    final r = await boot(tester);
    await go(tester, r, '/c/7');
    final page = seen.last;
    final scope = scopes.last;
    expect(scope.uri.path, '/c/7');
    expect(scoped[scope.id], page);
    expect(page.id, scope.id);
    expect(page.route.id, 7);
    // So a state reached through the scope's key is the one the page shows.
    expect(container.read(draft(scoped[scope.id]!)), 1);
    expect(find.textContaining('draft 1'), findsOneWidget);
    expect(builds, 1);
  });

  testWidgets('usePageInstance is one object for the life of the instance', (
    tester,
  ) async {
    final r = await boot(tester);
    await go(tester, r, '/h/1');
    await go(tester, r, '/h/1?q=2');
    await go(tester, r, '/h/1?q=3');
    expect(seen, isNotEmpty);
    expect(seen.every((p) => identical(p, seen.first)), isTrue);
    expect(seen.first.route.id, 1);
    expect(find.text('hook 1'), findsOneWidget);
    await go(tester, r, '/h/2');
    expect(seen.last, isNot(seen.first));
    expect(find.text('hook 2'), findsOneWidget);
  });

  group('holdForPage', () {
    testWidgets('keeps a state nobody watches, until the page leaves', (
      tester,
    ) async {
      final r = await boot(tester);
      await go(tester, r, '/t/1');
      final page = scoped.values.single;
      final tab = scopes.firstWhere((s) => s.uri.path == '/t/1');
      final value = container.read(draft(page));
      await settle(tester);
      expect(container.read(draft(page)), value, reason: 'held by the scope');
      expect((builds, disposes), (1, 0));

      // A parked tab: the page is on a navigator, the state stays.
      await go(tester, r, '/b');
      expect(find.text('b'), findsOneWidget);
      expect(tab.isActive, isTrue);
      expect((builds, disposes), (1, 0));

      // Leaving the shell ends the scope and with it the state.
      await go(tester, r, '/x');
      expect(tab.isActive, isFalse);
      expect(disposes, 1);
    });

    testWidgets('without it, a state nobody watches is gone', (tester) async {
      final r = await boot(tester);
      await go(tester, r, '/u/1');
      final page = scoped.values.single;
      final value = container.read(draft(page));
      await settle(tester);
      expect(disposes, 1);
      expect(container.read(draft(page)), isNot(value));
    });

    test('is scope.hold, and ends with the scope', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final scope = TestRouteScope(c, id: 'p#/c/1');
      final page = PageInstance.ofScope(scope, const CRoute(1));
      serials = 0;
      builds = 0;
      disposes = 0;
      holdForPage(scope, draft(page));
      expect(c.read(draft(page)), 1);
      expect(disposes, 0);
      scope.leave();
      await c.pump();
      expect(disposes, 1);
      expect(() => holdForPage(scope, draft(page)), throwsA(isA<StateError>()));
    });
  });
}
