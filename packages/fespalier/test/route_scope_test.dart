// RouteScope (since 0.11.0): the scope of one page instance an observe.dart `onEnter` takes.
// It lives exactly as long as the lifecycle's instance: a parked tab keeps it, another segment
// value is another one, a query change is not.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the hooks and the callbacks saw, in order.
final List<String> log = [];

/// The scopes the hooks were given, in order.
final List<RouteScope> scopes = [];

/// What `pageInstanceId` said in the builders of the pages, by label.
final Map<String, String> built = {};

/// Every id the builders of `/x` saw, in order (a page pushed twice builds two).
final List<String> builtX = [];

/// Builds and disposes of the held provider.
int builds = 0;
int disposes = 0;

/// The container of the last `boot`.
ProviderContainer? bootContainer;

final held = Provider.autoDispose<int>((ref) {
  builds++;
  ref.onCancel(() => log.add('cancel'));
  ref.onDispose(() => disposes++);
  return 1;
});

Widget page(String label) => Scaffold(body: Text(label));

List<RouteHooks> hooksFor(
  Uri uri, {
  void Function(RouteScope scope)? onEnter,
}) => [
  RouteHooks(
    'observe.dart',
    onEnter: (ref, scope) {
      scopes.add(scope);
      log.add('enter ${uri.path}');
      if (uri.path != '/x') scope.hold(held);
      scope.onLeave(() => log.add('callback 1 ${uri.path}'));
      scope.onLeave(() => log.add('callback 2 ${uri.path}'));
      onEnter?.call(scope);
    },
    onLeave: (ref) => log.add('hook leave ${uri.path}'),
  ),
];

GoRouter router({
  String initial = '/a',
  List<RouteHooks> Function(Uri uri)? hooks,
  ProviderContainer? container,
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
                builder: (_, s) {
                  built['a'] = pageInstanceId(s);
                  return page('a');
                },
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (_, s) {
                      built['a/id'] = pageInstanceId(s);
                      return page('a ${s.pathParameters['id']}');
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/b',
                builder: (_, s) {
                  built['b'] = pageInstanceId(s);
                  return page('b');
                },
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/x',
        builder: (_, s) {
          built['x'] = pageInstanceId(s);
          builtX.add(built['x']!);
          return page('x');
        },
      ),
      GoRoute(
        path: '/rm/:id',
        pageBuilder: (context, state) {
          built['rm'] = pageInstanceId(state);
          return remountPage(
            context,
            state,
            remountKey(state, Remount.onLocation, const ['id']),
            page('rm'),
          );
        },
      ),
    ],
  );
  observeAttach(r, hooks ?? hooksFor, container: container);
  return r;
}

Future<GoRouter> boot(
  WidgetTester tester, {
  String initial = '/a',
  List<RouteHooks> Function(Uri uri)? hooks,
}) async {
  log.clear();
  scopes.clear();
  built.clear();
  builtX.clear();
  builds = 0;
  disposes = 0;
  final r = router(initial: initial, hooks: hooks);
  bootContainer = await pumpRouter(tester, r);
  return r;
}

Future<void> go(WidgetTester tester, GoRouter r, String location) async {
  log.clear();
  r.go(location);
  await tester.pumpAndSettle();
  // Riverpod disposes an unlistened provider in a task it schedules, not in close().
  await tester.runAsync(() => bootContainer!.pump());
}

void main() {
  testWidgets(
    'hold keeps an autoDispose provider alive until the page leaves',
    (tester) async {
      final r = await boot(tester);
      expect((builds, disposes), (1, 0));
      await tester.pump();
      expect(disposes, 0, reason: 'nobody watches it, the scope holds it');
      await go(tester, r, '/x');
      expect(disposes, 1);
      expect(scopes.first.isActive, isFalse);
    },
  );

  testWidgets(
    'at leave: the hooks, then the callbacks newest first, then close',
    (tester) async {
      final r = await boot(
        tester,
        hooks: (uri) => [
          RouteHooks(
            'observe.dart',
            onEnter: (ref, scope) {
              if (uri.path != '/x') scope.hold(held);
              scope.onLeave(() => log.add('callback 1'));
              scope.onLeave(() => log.add('callback 2'));
            },
            onLeave: (ref) => log.add('hook'),
          ),
        ],
      );
      await go(tester, r, '/x');
      // `onCancel` fires when the last listener goes: the subscription closed last.
      expect(log, ['hook', 'callback 2', 'callback 1', 'cancel']);
      expect(disposes, 1);
    },
  );

  testWidgets('a parked tab keeps its scope, and focus is the same scope', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/2');
    final first = scopes.single;
    await go(tester, r, '/b');
    expect(first.isActive, isTrue);
    expect(log, ['enter /b']);
    expect(disposes, 0);
    await go(tester, r, '/a/2');
    expect(scopes, hasLength(2), reason: 'only /b made a new scope');
    expect(first.isActive, isTrue);
    expect(first.id, built['a/id']);
  });

  testWidgets('a segment change gives a new scope, a query change does not', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/1');
    final first = scopes.single;
    await go(tester, r, '/a/1?q=2');
    expect(scopes, [first]);
    expect(first.isActive, isTrue);
    await go(tester, r, '/a/2');
    expect(first.isActive, isFalse);
    expect(scopes, hasLength(2));
    expect(scopes.last.isActive, isTrue);
    expect(scopes.last.id, isNot(first.id));
    expect(scopes.last.uri.path, '/a/2');
  });

  testWidgets('remount: onLocation with a query change keeps the scope', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/rm/1');
    final first = scopes.single;
    await go(tester, r, '/rm/1?q=2');
    expect(scopes, [first]);
    expect(first.isActive, isTrue);
    expect(first.id, built['rm']);
    await go(tester, r, '/rm/2');
    expect(first.isActive, isFalse);
  });

  testWidgets('a page pushed twice is two scopes', (tester) async {
    final r = await boot(tester, initial: '/a');
    unawaited(r.push<void>('/x'));
    await tester.pumpAndSettle();
    final one = scopes.last;
    unawaited(r.push<void>('/x'));
    await tester.pumpAndSettle();
    final two = scopes.last;
    expect(one.id, isNot(two.id));
    expect(one.isActive && two.isActive, isTrue, reason: 'covered, not gone');
    expect(builtX.toSet(), {one.id, two.id});
    r.pop();
    await tester.pumpAndSettle();
    expect(two.isActive, isFalse);
    expect(one.isActive, isTrue);
  });

  testWidgets('a throwing callback is reported and the others still run', (
    tester,
  ) async {
    final reported = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = old);
    final r = await boot(
      tester,
      hooks: (uri) => [
        RouteHooks(
          'observe.dart',
          onEnter: (ref, scope) {
            if (uri.path != '/x') scope.hold(held);
            scope.onLeave(() => log.add('first'));
            scope.onLeave(() => throw StateError('nope'));
            scope.onLeave(() => log.add('last'));
          },
        ),
      ],
    );
    await go(tester, r, '/x');
    expect(log, ['last', 'first', 'cancel']);
    expect(disposes, 1);
    expect(reported, hasLength(1));
    expect(reported.single.exception.toString(), contains('nope'));
    expect(
      reported.single.context.toString(),
      contains('while running a RouteScope.onLeave callback of'),
    );
  });

  testWidgets('hold and onLeave after the page left throw a StateError', (
    tester,
  ) async {
    final r = await boot(tester);
    await go(tester, r, '/x');
    final gone = scopes.first;
    expect(() => gone.hold(held), throwsStateError);
    expect(() => gone.onLeave(() {}), throwsStateError);
  });

  testWidgets('pageInstanceId(state) is the id the scope reports', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/1');
    expect(scopes.single.id, built['a/id']);
    await go(tester, r, '/b');
    expect(scopes.last.id, built['b']);
    unawaited(r.push<void>('/x'));
    await tester.pumpAndSettle();
    expect(scopes.last.id, built['x']);
    expect(built['x'], contains('@/x'));
    expect(built['b'], contains('#/b'));
  });

  testWidgets('the container passed to observeAttach is the one holding', (
    tester,
  ) async {
    log.clear();
    scopes.clear();
    builds = 0;
    disposes = 0;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final r = router(container: container);
    await pumpRouter(tester, r);
    expect(builds, 1);
    final other = ProviderScope.containerOf(
      tester.element(find.text('a')),
      listen: false,
    );
    expect(other.exists(held), isFalse, reason: 'held in the given container');
    expect(container.exists(held), isTrue);
  });

  testWidgets('two observe.dart files of a page share one scope', (
    tester,
  ) async {
    final seen = <RouteScope>[];
    final r = await boot(
      tester,
      hooks: (uri) => [
        RouteHooks('a/observe.dart', onEnter: (ref, scope) => seen.add(scope)),
        RouteHooks('b/observe.dart', onEnter: (ref, scope) => seen.add(scope)),
      ],
    );
    expect(seen, hasLength(2));
    expect(identical(seen[0], seen[1]), isTrue);
    await go(tester, r, '/x');
    expect(seen.first.isActive, isFalse);
  });

  testWidgets(
    'replace on a tree page keeps its key: a query is no transition',
    (tester) async {
      final r = await boot(tester, initial: '/a/1');
      final first = scopes.single;
      log.clear();
      unawaited(r.replace<void>('/a/1?q=2'));
      await tester.pumpAndSettle();
      expect(scopes, [first]);
      expect(first.isActive, isTrue);
      expect(log, isEmpty);
      unawaited(r.replace<void>('/a/2'));
      await tester.pumpAndSettle();
      expect(first.isActive, isFalse);
      expect(scopes, hasLength(2));
      expect(scopes.last.id, contains('#/a/2'));
    },
  );

  testWidgets('pushReplacement on a tree page ends it and starts a new scope', (
    tester,
  ) async {
    final r = await boot(tester, initial: '/a/1');
    final first = scopes.single;
    unawaited(r.pushReplacement<void>('/x'));
    await tester.pumpAndSettle();
    expect(first.isActive, isFalse);
    expect(scopes.last.id, contains('@/x'));
    expect(scopes.last.isActive, isTrue);
  });

  testWidgets(
    'a navigation that a redirect sends elsewhere scopes the final page',
    (tester) async {
      final r = GoRouter(
        initialLocation: '/a',
        redirect: (_, s) => s.uri.path == '/go' ? '/x' : null,
        routes: [
          GoRoute(path: '/a', builder: (_, _) => page('a')),
          GoRoute(path: '/x', builder: (_, _) => page('x')),
          GoRoute(path: '/go', builder: (_, _) => page('go')),
        ],
      );
      log.clear();
      scopes.clear();
      observeAttach(r, hooksFor);
      await pumpRouter(tester, r);
      r.go('/go');
      await tester.pumpAndSettle();
      expect(scopes.map((s) => s.uri.path), ['/a', '/x']);
      scopes.last.hold(held);
      expect(scopes.last.isActive, isTrue);
    },
  );

  testWidgets('disposing the container ends the scope: its callbacks run', (
    tester,
  ) async {
    log.clear();
    scopes.clear();
    final container = ProviderContainer();
    final r = router(container: container);
    await pumpRouter(tester, r, container: container);
    expect(scopes.single.isActive, isTrue);
    await tester.pumpWidget(const SizedBox());
    log.clear();
    container.dispose();
    expect(scopes.single.isActive, isFalse);
    expect(log, ['callback 2 /a', 'callback 1 /a', 'cancel']);
  });

  test('a scope that ends adds no microtask and no timer of its own', () {
    (int, int) scheduled({required bool scoped}) {
      var count = (-1, -1);
      fakeAsync((async) {
        final container = ProviderContainer();
        if (scoped) {
          final scope = TestRouteScope(container)
            ..hold(held)
            ..onLeave(() {});
          scope.leave();
        } else {
          // The two listens a scope makes (the held provider and its own), closed.
          container.listen<Object?>(held, (_, _) {}).close();
          container
              .listen<Object?>(Provider.autoDispose((ref) => 1), (_, _) {})
              .close();
        }
        count = (async.microtaskCount, async.pendingTimers.length);
        container.dispose();
      });
      return count;
    }

    // Riverpod schedules work for a listener and for a close; the scope adds nothing to that.
    expect(scheduled(scoped: true), scheduled(scoped: false));
  });
}
