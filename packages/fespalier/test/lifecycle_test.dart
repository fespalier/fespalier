// The observe.dart hooks (since 0.8.1): `observeAttach` diffs the router's committed
// configuration at the end of the first frame that shows a change. A page instance is entered
// the first time it is the page the user sees, focused when it is on top again, and left when
// it is on no navigator any more. The routers here are hand-built, with the hooks the
// generated `_observeAt` would give.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the hooks saw, in order: `enter /a/1`, `leave /a/1`, `focus /a`.
final List<String> log = [];

final Provider<int> three = Provider<int>((ref) => 3);

/// What a hook writes down by changing a provider.
class Views extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void add(String view) => state = [...state, view];
}

final NotifierProvider<Views, List<String>> views =
    NotifierProvider<Views, List<String>>(Views.new);

/// The hooks of the observe.dart of the whole app: they log the path they were bound for, which
/// is what a generated hook gets as `uri`.
List<RouteHooks> everywhere(Uri uri) => [
  RouteHooks(
    'observe.dart',
    onEnter: (ref) => log.add('enter ${uri.path}'),
    onLeave: (ref) => log.add('leave ${uri.path}'),
    onFocus: (ref) => log.add('focus ${uri.path}'),
  ),
];

Widget page(String label) => Scaffold(body: Text(label));

GoRouter router({
  String initial = '/a',
  List<RouteHooks> Function(Uri uri)? hooks,
  bool attach = true,
  FutureOr<String?> Function(BuildContext, GoRouterState)? guarded,
  bool preloadB = false,
}) {
  final r = GoRouter(
    initialLocation: initial,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/a',
                builder: (_, _) => page('a'),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (_, s) => page('a ${s.pathParameters['id']}'),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            preload: preloadB,
            routes: [
              GoRoute(path: '/b', builder: (_, _) => page('b')),
              GoRoute(path: '/b2', builder: (_, _) => page('b2')),
            ],
          ),
        ],
      ),
      GoRoute(path: '/x', builder: (_, _) => page('x')),
      GoRoute(path: '/y', builder: (_, _) => page('y')),
      GoRoute(path: '/old', redirect: (_, _) => '/b'),
      GoRoute(
        path: '/products/:id',
        builder: (_, s) => page('product ${s.pathParameters['id']}'),
      ),
      GoRoute(path: '/products', builder: (_, _) => page('products')),
      if (guarded != null)
        GoRoute(
          path: '/guarded',
          redirect: guarded,
          builder: (_, _) => page('guarded'),
        ),
    ],
  );
  if (attach) observeAttach(r, hooks ?? everywhere);
  return r;
}

Future<GoRouter> boot(
  WidgetTester tester, {
  String initial = '/a',
  List<RouteHooks> Function(Uri uri)? hooks,
  FutureOr<String?> Function(BuildContext, GoRouterState)? guarded,
  bool preloadB = false,
}) async {
  log.clear();
  final r = router(
    initial: initial,
    hooks: hooks,
    guarded: guarded,
    preloadB: preloadB,
  );
  await pumpRouter(tester, r);
  return r;
}

Future<void> go(WidgetTester tester, GoRouter r, String location) async {
  log.clear();
  r.go(location);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the first page enters once the first frame is built', (
    tester,
  ) async {
    await boot(tester);
    expect(log, ['enter /a']);
  });

  testWidgets('nothing fires during build: the hook runs after the frame', (
    tester,
  ) async {
    log.clear();
    final r = router();
    addTearDown(r.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: r)),
    );
    // The first frame is built and its post-frame callbacks have run.
    expect(log, ['enter /a']);
    r.go('/x');
    expect(log, ['enter /a'], reason: 'not at go(): the frame has not run');
    await tester.pump();
    expect(log, ['enter /a', 'leave /a', 'enter /x']);
  });

  testWidgets('a nested page enters, and the page it covers is not left', (
    tester,
  ) async {
    final r = await boot(tester);
    await go(tester, r, '/a/1');
    expect(log, ['enter /a/1']);
  });

  testWidgets('another segment value is another page: leave, then enter', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/1');
    expect(log, ['enter /a/1']);
    await go(tester, r, '/a/2');
    expect(log, ['leave /a/1', 'enter /a/2']);
  });

  testWidgets('a refresh, a rebuild and a query change fire nothing', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/1');
    log.clear();
    r.refresh();
    await tester.pumpAndSettle();
    expect(log, isEmpty);
    r.go('/a/1?tab=2');
    await tester.pumpAndSettle();
    expect(log, isEmpty);
  });

  testWidgets('a tab switch enters the other tab; the first tab is parked', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/2');
    await go(tester, r, '/b');
    expect(log, ['enter /b']);
    log.clear();
    // Back to the first tab: its page was only parked.
    r.go('/a/2');
    await tester.pumpAndSettle();
    expect(log, ['focus /a/2']);
  });

  testWidgets('goBranch focuses the page the tab kept', (tester) async {
    final r = await boot(tester, initial: '/a/2');
    final shell = StatefulNavigationShell.of(tester.element(find.text('a 2')));
    log.clear();
    shell.goBranch(1);
    await tester.pumpAndSettle();
    expect(log, ['enter /b']);
    log.clear();
    shell.goBranch(0);
    await tester.pumpAndSettle();
    expect(log, ['focus /a/2']);
    expect(r.routerDelegate.currentConfiguration.uri.path, '/a/2');
  });

  testWidgets('going to a page of the parked tab leaves its old page', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/2');
    await go(tester, r, '/b');
    await go(tester, r, '/a/5');
    // `/a/2` was parked, and the tab is current again with another page: it is gone.
    expect(log, ['leave /a/2', 'enter /a/5']);
  });

  testWidgets('push enters the pushed page, pop leaves it and focuses', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/2');
    log.clear();
    unawaited(r.push<void>('/x'));
    await tester.pumpAndSettle();
    expect(log, ['enter /x']);
    log.clear();
    r.pop();
    await tester.pumpAndSettle();
    expect(log, ['leave /x', 'focus /a/2']);
  });

  testWidgets('replace on a pushed page leaves the old and enters the new', (
    tester,
  ) async {
    final r = await boot(tester);
    unawaited(r.push<void>('/x'));
    await tester.pumpAndSettle();
    log.clear();
    unawaited(r.replace<void>('/y'));
    await tester.pumpAndSettle();
    expect(log, ['leave /x', 'enter /y']);
  });

  testWidgets('pushReplacement leaves the page and enters the new one', (
    tester,
  ) async {
    final r = await boot(tester);
    log.clear();
    unawaited(r.pushReplacement<void>('/x'));
    await tester.pumpAndSettle();
    expect(log, ['leave /a', 'enter /x']);
  });

  testWidgets('a redirect never enters the location it redirected from', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/b');
    await go(tester, r, '/x');
    await go(tester, r, '/old');
    expect(log, ['leave /x', 'enter /b']);
  });

  testWidgets('a guard that redirects shows only the final location', (
    tester,
  ) async {
    final r = await boot(tester, guarded: (_, _) => '/b2');
    await go(tester, r, '/guarded');
    expect(log, ['enter /b2']);
  });

  testWidgets('an async guard enters after it settles, and not before', (
    tester,
  ) async {
    final answer = Completer<String?>();
    final r = await boot(tester, guarded: (_, _) => answer.future);
    log.clear();
    r.go('/guarded');
    await tester.pump();
    expect(log, isEmpty, reason: 'nothing committed yet');
    answer.complete('/x');
    await tester.pumpAndSettle();
    expect(log, ['leave /a', 'enter /x']);
  });

  testWidgets('leaving the shell leaves every entered page, newest first', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a');
    await go(tester, r, '/a/2');
    await go(tester, r, '/b');
    await go(tester, r, '/x');
    expect(log, ['leave /b', 'leave /a/2', 'leave /a', 'enter /x']);
  });

  testWidgets('a deep link enters the leaf only; its parent enters on pop', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/products/1');
    expect(log, ['enter /products/1']);
    log.clear();
    r.go('/products');
    await tester.pumpAndSettle();
    expect(log, ['leave /products/1', 'enter /products']);
  });

  testWidgets('a location that matches no route leaves the page', (
    tester,
  ) async {
    final r = await boot(tester);
    await go(tester, r, '/nowhere');
    expect(log, ['leave /a']);
  });

  testWidgets('a preloaded tab does not enter', (tester) async {
    await boot(tester, preloadB: true);
    expect(log, ['enter /a']);
  });

  testWidgets('a custom container builder keeps the same rules', (
    tester,
  ) async {
    log.clear();
    final r = GoRouter(
      initialLocation: '/a',
      routes: [
        StatefulShellRoute(
          builder: (context, state, shell) => shell,
          navigatorContainerBuilder: (context, shell, children) =>
              children[shell.currentIndex],
          branches: [
            StatefulShellBranch(
              routes: [GoRoute(path: '/a', builder: (_, _) => page('a'))],
            ),
            StatefulShellBranch(
              routes: [GoRoute(path: '/b', builder: (_, _) => page('b'))],
            ),
          ],
        ),
      ],
    );
    observeAttach(r, everywhere);
    await pumpRouter(tester, r);
    expect(log, ['enter /a']);
    await go(tester, r, '/b');
    expect(log, ['enter /b']);
    await go(tester, r, '/a');
    expect(log, ['focus /a']);
  });

  testWidgets('a pushed dialog page enters and leaves like any page', (
    tester,
  ) async {
    log.clear();
    final r = GoRouter(
      initialLocation: '/a',
      routes: [
        GoRoute(path: '/a', builder: (_, _) => page('a')),
        GoRoute(
          path: '/dialog',
          pageBuilder: (context, state) => DialogPage<void>(
            key: state.pageKey,
            builder: (_) => const AlertDialog(content: Text('dialog')),
          ),
        ),
      ],
    );
    observeAttach(r, everywhere);
    await pumpRouter(tester, r);
    log.clear();
    unawaited(r.push<void>('/dialog'));
    await tester.pumpAndSettle();
    expect(log, ['enter /dialog']);
    log.clear();
    r.pop();
    await tester.pumpAndSettle();
    expect(log, ['leave /dialog', 'focus /a']);
  });

  group('remount', () {
    testWidgets('a query change is no transition, even under onLocation', (
      tester,
    ) async {
      log.clear();
      final r = GoRouter(
        initialLocation: '/x/1',
        routes: [
          GoRoute(
            path: '/x/:id',
            pageBuilder: (context, state) => remountPage(
              context,
              state,
              remountKey(state, Remount.onLocation, const ['id']),
              page('x'),
            ),
          ),
        ],
      );
      observeAttach(r, everywhere);
      await pumpRouter(tester, r);
      log.clear();
      r.go('/x/1?q=2');
      await tester.pumpAndSettle();
      expect(log, isEmpty);
      r.go('/x/2');
      await tester.pumpAndSettle();
      expect(log, ['leave /x/1', 'enter /x/2']);
    });

    testWidgets('a segment change is a new instance whatever remount says', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/products/1');
      await go(tester, r, '/products/2');
      expect(log, ['leave /products/1', 'enter /products/2']);
    });
  });

  group('hooks', () {
    testWidgets('enter and focus run outermost first, leave innermost first', (
      tester,
    ) async {
      List<RouteHooks> two(Uri uri) => [
        RouteHooks(
          'observe.dart',
          onEnter: (_) => log.add('enter outer'),
          onFocus: (_) => log.add('focus outer'),
          onLeave: (_) => log.add('leave outer'),
        ),
        RouteHooks(
          'products/\$id/observe.dart',
          onEnter: (_) => log.add('enter inner'),
          onFocus: (_) => log.add('focus inner'),
          onLeave: (_) => log.add('leave inner'),
        ),
      ];
      final r = await boot(tester, hooks: two);
      expect(log, ['enter outer', 'enter inner']);
      unawaited(r.push<void>('/x'));
      await tester.pumpAndSettle();
      log.clear();
      r.pop();
      await tester.pumpAndSettle();
      expect(log, ['leave inner', 'leave outer', 'focus outer', 'focus inner']);
    });

    testWidgets('a hook gets a Ref that reads providers', (tester) async {
      var read = 0;
      await boot(
        tester,
        hooks: (_) => [
          RouteHooks('observe.dart', onEnter: (ref) => read = ref.read(three)),
        ],
      );
      expect(read, 3);
    });

    testWidgets('a hook may change another provider', (tester) async {
      await boot(
        tester,
        hooks: (uri) => [
          RouteHooks(
            'observe.dart',
            onEnter: (ref) => ref.read(views.notifier).add('enter ${uri.path}'),
            onLeave: (ref) => ref.read(views.notifier).add('leave ${uri.path}'),
          ),
        ],
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold)),
      );
      expect(container.read(views), ['enter /a']);
    });

    testWidgets('a hook that throws is reported, and the next one still runs', (
      tester,
    ) async {
      final r = router(
        hooks: (_) => [
          RouteHooks(
            'products/\$id/observe.dart',
            onEnter: (_) => throw StateError('nope'),
          ),
          RouteHooks('observe.dart', onEnter: (_) => log.add('second')),
        ],
      );
      log.clear();
      final reported = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = old);
      await pumpRouter(tester, r);
      expect(log, ['second']);
      expect(reported, hasLength(1));
      expect(reported.single.library, 'fespalier');
      expect(
        reported.single.context.toString(),
        'while running onEnter of products/\$id/observe.dart',
      );
      expect(reported.single.exception.toString(), contains('nope'));
    });

    testWidgets(
      'a hook may navigate: it is diffed at the end of the next frame',
      (tester) async {
        final r = await boot(
          tester,
          hooks: (uri) => [
            RouteHooks(
              'observe.dart',
              onEnter: (ref) {
                log.add('enter ${uri.path}');
                if (uri.path == '/y') ref.read(goTo)('/x');
              },
              onLeave: (_) => log.add('leave ${uri.path}'),
            ),
          ],
        );
        goTarget = r;
        await go(tester, r, '/y');
        expect(log, ['leave /a', 'enter /y', 'leave /y', 'enter /x']);
      },
    );

    testWidgets('a router with no observe.dart hooks bound runs nothing', (
      tester,
    ) async {
      await boot(tester, hooks: (_) => const []);
      expect(log, isEmpty);
    });

    testWidgets('onLeave gets the parameters the page entered with', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/products/1');
      await go(tester, r, '/products/2');
      expect(log, ['leave /products/1', 'enter /products/2']);
    });
  });

  group('pumpRouter', () {
    testWidgets('leaves no timer and needs no runAsync', (tester) async {
      final r = await boot(tester);
      await go(tester, r, '/x');
      await go(tester, r, '/a');
      expect(log, ['leave /x', 'enter /a']);
      // The test binding fails the test when a timer is left pending.
    });

    testWidgets('a router disposed with pages entered fires no more hooks', (
      tester,
    ) async {
      final r = await boot(tester);
      log.clear();
      r.go('/x');
      r.dispose();
      await tester.pumpWidget(const SizedBox());
      expect(log, isEmpty);
    });
  });
}

GoRouter? goTarget;

/// A provider that gives a hook a way to navigate: `ref.read(goTo)('/x')`.
final Provider<void Function(String)> goTo = Provider<void Function(String)>(
  (ref) =>
      (location) => goTarget!.go(location),
);

/// A dialog as a page, the way a `present.dart` builds one.
class DialogPage<T> extends Page<T> {
  const DialogPage({required this.builder, super.key});

  final WidgetBuilder builder;

  @override
  Route<T> createRoute(BuildContext context) =>
      DialogRoute<T>(context: context, settings: this, builder: builder);
}
