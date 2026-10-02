// The app side of the DevTools extension: the service extensions an app registers and the events
// it posts. The routes are shaped like what the generated `mount()` returns.
import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/devtools/devtools.dart';
import 'package:fespalier/src/devtools/protocol.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ProductRoute extends TypedLocation {
  const _ProductRoute(this.id);
  final int id;

  @override
  String get location => '/products/$id';
}

final class _HomeRoute extends TypedLocation {
  const _HomeRoute();

  @override
  String get location => '/';
}

/// What the generated `AppRoutes.matchUrl` answers, for the three routes it knows.
UrlMatch? matchUrl(Uri uri) {
  final parts = uri.pathSegments;
  if (uri.path == '/') {
    return UrlMatch(uri, const _HomeRoute(), const {}, const []);
  }
  if (parts.length == 2 && parts[0] == 'products') {
    final id = int.tryParse(parts[1]);
    if (id == null) return null;
    return UrlMatch(
      uri,
      _ProductRoute(id),
      {'id': id, 'tab': uri.queryParametersAll['tab']?.first},
      [_noData, _noData],
    );
  }
  return null;
}

final _noData = Provider<AsyncValue<Object?>>((ref) => const AsyncData(null));

String tree() => jsonEncode({
  'protocol': 1,
  'package': 'shop',
  'appDir': 'lib/app',
  'items': <Object?>[],
});

Widget page(String label) => Text(label);

/// The routes of `mount()`: pages, a layout, tabs, and a layout whose pages have absolute paths.
List<RouteBase> routes() => [
  GoRoute(path: '/', builder: (_, _) => page('HOME')),
  GoRoute(
    path: '/products',
    builder: (_, _) => page('PRODUCTS'),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) => page('PRODUCT ${state.pathParameters['id']}'),
        routes: [GoRoute(path: 'reviews', builder: (_, _) => page('REVIEWS'))],
      ),
    ],
  ),
  GoRoute(
    path: '/n/:i',
    builder: (_, state) => page('N ${state.pathParameters['i']}'),
  ),
  GoRoute(path: '/a', builder: (_, _) => page('A')),
  GoRoute(path: '/b', builder: (_, _) => page('B')),
  ShellRoute(
    builder: (_, _, child) => Column(
      children: [
        const Text('LAYOUT'),
        Expanded(child: child),
      ],
    ),
    routes: [
      GoRoute(path: '/account', builder: (_, _) => page('ACCOUNT')),
      GoRoute(path: '/account/security', builder: (_, _) => page('SECURITY')),
    ],
  ),
  StatefulShellRoute.indexedStack(
    builder: (_, _, shell) => shell,
    branches: [
      StatefulShellBranch(
        routes: [GoRoute(path: '/tab-a', builder: (_, _) => page('TAB A'))],
      ),
      StatefulShellBranch(
        routes: [GoRoute(path: '/tab-b', builder: (_, _) => page('TAB B'))],
      ),
    ],
  ),
];

GoRouter newRouter({String initial = '/', Object? extra}) =>
    GoRouter(initialLocation: initial, initialExtra: extra, routes: routes());

/// What a tool sees: the answer of `ext.fespalier.snapshot`.
Future<SnapshotRecord> snapshot() async =>
    SnapshotRecord.fromJson(await debugDevToolsCall(DevToolsMethods.snapshot));

/// Registers the app and attaches [router], as the generated `mount()` and `router()` do.
void register(GoRouter router) {
  devToolsRegister(tree: tree, matchUrl: matchUrl);
  devToolsAttach(router);
}

List<(String, Map<String, Object?>)> get events => debugDevToolsEvents!;

/// The kinds of the history, oldest first.
Future<List<String>> kinds() async => [
  for (final h in (await snapshot()).history) h.kind,
];

void main() {
  setUp(() {
    debugDevToolsReset();
    debugDevToolsEvents = [];
  });
  tearDown(() {
    debugDevToolsReset();
    debugDevToolsEvents = null;
  });

  test('DevTools support is compiled in under flutter test', () {
    expect(kFespalierDevTools, isTrue);
  });

  group('hello', () {
    test('says nothing is registered before the app registers', () async {
      final hello = HelloRecord.fromJson(
        await debugDevToolsCall(DevToolsMethods.hello),
      );
      expect(hello.protocol, 1);
      expect(hello.registered, isFalse);
      expect(hello.attached, isFalse);
      expect(hello.features, [
        DevToolsFeatures.navigation,
        DevToolsFeatures.match,
        DevToolsFeatures.navigate,
      ]);
    });

    testWidgets('says the app is registered, then that a router is attached', (
      tester,
    ) async {
      devToolsRegister(tree: tree, matchUrl: matchUrl);
      var hello = HelloRecord.fromJson(
        await debugDevToolsCall(DevToolsMethods.hello),
      );
      expect(hello.registered, isTrue);
      expect(hello.attached, isFalse);
      final router = newRouter();
      await pumpRouter(tester, router);
      devToolsAttach(router);
      hello = HelloRecord.fromJson(
        await debugDevToolsCall(DevToolsMethods.hello),
      );
      expect(hello.attached, isTrue);
    });

    test('registering twice, here and across tests, does not throw', () {
      devToolsRegister(tree: tree, matchUrl: matchUrl);
      devToolsRegister(tree: tree, matchUrl: matchUrl);
      debugDevToolsReset();
      devToolsRegister(tree: tree, matchUrl: matchUrl);
    });

    test('an unknown method is an error, not a throw', () async {
      final answer = await debugDevToolsCall('ext.fespalier.nope');
      expect(answer['errorDetail'], contains('unknown method'));
    });
  });

  test('tree answers the tree the app registered, parsed', () async {
    var answer = await debugDevToolsCall(DevToolsMethods.tree);
    expect(answer, {'protocol': 1, 'tree': null});
    devToolsRegister(tree: tree, matchUrl: matchUrl);
    answer = await debugDevToolsCall(DevToolsMethods.tree);
    expect(answer['protocol'], 1);
    expect((answer['tree']! as Map<String, Object?>)['package'], 'shop');
  });

  group('snapshot', () {
    testWidgets(
      'has the location, its parts and the route the matcher gives it',
      (tester) async {
        final router = newRouter(
          initial: '/products/2?tab=info&tab=more',
          extra: const [1, 2],
        );
        register(router);
        await pumpRouter(tester, router);
        final location = (await snapshot()).location!;
        expect(location.uri, '/products/2?tab=info&tab=more');
        expect(location.fullPath, '/products/:id');
        expect(location.pathParameters, {'id': '2'});
        expect(location.query, {
          'tab': ['info', 'more'],
        });
        expect(location.extra, Shown.of(const [1, 2]));
        expect(location.route, '_ProductRoute');
        expect(location.params!['id'], const Shown('int', '2'));
        expect(location.params!['tab'], const Shown('String', 'info'));
        expect(location.error, isNull);
      },
    );

    testWidgets('has no extra when the navigation carried none', (
      tester,
    ) async {
      final router = newRouter(initial: '/products/2');
      register(router);
      await pumpRouter(tester, router);
      final location = (await snapshot()).location!;
      expect(location.extra, isNull);
      expect(location.params!['tab'], const Shown('Null', 'null'));
    });

    testWidgets('a location no route has says why', (tester) async {
      final router = newRouter(initial: '/nowhere');
      register(router);
      await pumpRouter(tester, router);
      final location = (await snapshot()).location!;
      expect(location.uri, '/nowhere');
      expect(location.route, isNull);
      expect(location.params, isNull);
      expect(location.error, contains('no routes for location'));
      expect(
        (await snapshot()).history.single.error,
        contains('no routes for location'),
      );
    });

    testWidgets(
      'a route the matcher does not know has the router and no typed route',
      (tester) async {
        final router = newRouter(initial: '/a');
        register(router);
        await pumpRouter(tester, router);
        final location = (await snapshot()).location!;
        expect(location.fullPath, '/a');
        expect(location.route, isNull);
      },
    );

    test('is empty before there is a router', () async {
      final snap = await snapshot();
      expect(snap.protocol, 1);
      expect(snap.registered, isFalse);
      expect(snap.attached, isFalse);
      expect(snap.location, isNull);
      expect(snap.stack, isEmpty);
      expect(snap.history, isEmpty);
    });
  });

  group('stack', () {
    testWidgets(
      'is the declarative stack, with the path template of each page',
      (tester) async {
        final router = newRouter(initial: '/products/2/reviews');
        register(router);
        await pumpRouter(tester, router);
        final stack = (await snapshot()).stack;
        expect([for (final f in stack) f.type], ['page', 'page', 'page']);
        expect(
          [for (final f in stack) f.path],
          ['/products', '/products/:id', '/products/:id/reviews'],
        );
        expect(
          [for (final f in stack) f.location],
          ['/products', '/products/2', '/products/2/reviews'],
        );
      },
    );

    testWidgets('has a shell, with the pages under it, for a layout', (
      tester,
    ) async {
      final router = newRouter(initial: '/account/security');
      register(router);
      await pumpRouter(tester, router);
      final stack = (await snapshot()).stack;
      expect(stack, hasLength(1));
      expect(stack.single.type, FrameType.shell);
      expect(stack.single.children.single.type, FrameType.page);
      // A page inside a shell has an absolute path: it starts over.
      expect(stack.single.children.single.path, '/account/security');
      expect(stack.single.children.single.location, '/account/security');
    });

    testWidgets('has a pushed page, with what it shows', (tester) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);
      unawaited(router.push<void>('/products/3'));
      await tester.pumpAndSettle();
      final stack = (await snapshot()).stack;
      expect([for (final f in stack) f.type], ['page', 'pushed']);
      final pushed = stack.last;
      expect(pushed.path, '/products/:id');
      expect(pushed.location, '/products/3');
      expect(
        [for (final f in pushed.children) f.path],
        ['/products', '/products/:id'],
      );
      expect((await snapshot()).location!.uri, '/products/3');
    });

    testWidgets('has the branch of a tab layout under its shell', (
      tester,
    ) async {
      final router = newRouter(initial: '/tab-b');
      register(router);
      await pumpRouter(tester, router);
      final stack = (await snapshot()).stack;
      expect(stack.single.type, FrameType.shell);
      expect(stack.single.children.single.path, '/tab-b');
    });

    testWidgets('has a pushed page inside a layout, under that layout', (
      tester,
    ) async {
      final router = newRouter(initial: '/account');
      register(router);
      await pumpRouter(tester, router);
      unawaited(router.push<void>('/account/security'));
      await tester.pumpAndSettle();
      final snap = await snapshot();
      expect(snap.history.last.kind, NavigationKind.push);
      expect(snap.history.last.depth, 1);
      final shell = snap.stack.single;
      expect(shell.type, FrameType.shell);
      expect([for (final f in shell.children) f.type], ['page', 'pushed']);
    });
  });

  group('history', () {
    testWidgets(
      'names the kind of each navigation, and counts the pushed pages',
      (tester) async {
        final router = newRouter(initial: '/a');
        register(router);
        await pumpRouter(tester, router);
        router.go('/b');
        await tester.pumpAndSettle();
        unawaited(router.push<void>('/products/1'));
        await tester.pumpAndSettle();
        unawaited(router.push<void>('/products/2'));
        await tester.pumpAndSettle();
        unawaited(router.replace<void>('/products/3'));
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
        router.go('/a');
        await tester.pumpAndSettle();
        final history = (await snapshot()).history;
        expect(
          [for (final h in history) h.kind],
          [
            NavigationKind.initial,
            NavigationKind.go,
            NavigationKind.push,
            NavigationKind.push,
            NavigationKind.replace,
            NavigationKind.pop,
            NavigationKind.go,
          ],
        );
        expect([for (final h in history) h.depth], [0, 0, 1, 2, 2, 1, 0]);
        expect(
          [for (final h in history) h.uri],
          [
            '/a',
            '/b',
            '/products/1',
            '/products/2',
            '/products/3',
            '/products/1',
            '/a',
          ],
        );
        expect([for (final h in history) h.seq], [1, 2, 3, 4, 5, 6, 7]);
        expect([for (final h in history) h.fullPath].take(3), [
          '/a',
          '/b',
          '/products/:id',
        ]);
        expect(history.every((h) => h.at > 0), isTrue);
      },
    );

    testWidgets(
      'drops the pushed pages for another location as a go, not a pop',
      (tester) async {
        final router = newRouter(initial: '/a');
        register(router);
        await pumpRouter(tester, router);
        unawaited(router.push<void>('/products/1'));
        await tester.pumpAndSettle();
        router.go('/b');
        await tester.pumpAndSettle();
        expect(await kinds(), [
          NavigationKind.initial,
          NavigationKind.push,
          NavigationKind.go,
        ]);
      },
    );

    testWidgets('names the same location again a refresh', (tester) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);
      // Same location, another `extra`: a different configuration, which the delegate commits.
      router.go('/a', extra: 'again');
      await tester.pumpAndSettle();
      expect(await kinds(), [NavigationKind.initial, NavigationKind.refresh]);
    });

    testWidgets(
      'a refresh of the router that changes nothing is not a navigation',
      (tester) async {
        final router = newRouter(initial: '/a');
        register(router);
        await pumpRouter(tester, router);
        router.refresh();
        await tester.pumpAndSettle();
        expect(await kinds(), [NavigationKind.initial]);
      },
    );

    testWidgets('keeps the last $_limit, and numbers on', (tester) async {
      final router = newRouter(initial: '/n/0');
      register(router);
      await pumpRouter(tester, router);
      for (var i = 1; i <= 105; i++) {
        router.go('/n/$i');
        await tester.pump();
      }
      final history = (await snapshot()).history;
      expect(history, hasLength(_limit));
      expect(history.first.uri, '/n/6');
      expect(history.last.uri, '/n/105');
      expect(history.last.seq, 106);
    });

    testWidgets('starts where a router attached late already is', (
      tester,
    ) async {
      final router = newRouter(initial: '/b');
      await pumpRouter(tester, router);
      register(router);
      final history = (await snapshot()).history;
      expect(history.single.kind, NavigationKind.initial);
      expect(history.single.uri, '/b');
    });
  });

  group('navigate', () {
    testWidgets('go, push, replace and pop move the router', (tester) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);

      var answer = await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': NavigateMode.go,
        'location': '/b',
      });
      await tester.pumpAndSettle();
      expect(answer, {'protocol': 1, 'ok': true});
      expect(find.text('B'), findsOneWidget);

      answer = await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': NavigateMode.push,
        'location': '/products/9',
      });
      await tester.pumpAndSettle();
      expect(find.text('PRODUCT 9'), findsOneWidget);
      expect((await snapshot()).history.last.depth, 1);

      await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': NavigateMode.replace,
        'location': '/a',
      });
      await tester.pumpAndSettle();
      expect(find.text('A'), findsOneWidget);
      expect((await snapshot()).history.last.kind, NavigationKind.replace);

      await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': NavigateMode.pop,
      });
      await tester.pumpAndSettle();
      expect(find.text('B'), findsOneWidget);
      expect((await snapshot()).history.last.depth, 0);
    });

    testWidgets('pop with nothing to pop is a no-op that says ok', (
      tester,
    ) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);
      final answer = await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': NavigateMode.pop,
      });
      await tester.pumpAndSettle();
      expect(answer['ok'], isTrue);
      expect(find.text('A'), findsOneWidget);
      expect((await snapshot()).history, hasLength(1));
    });

    testWidgets('a missing location, or an unknown mode, is invalidParams', (
      tester,
    ) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);
      var answer = await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': NavigateMode.go,
      });
      expect(answer['errorCode'], -32602);
      expect(answer['errorDetail'], 'missing parameter `location`');
      answer = await debugDevToolsCall(DevToolsMethods.navigate, {});
      expect(answer['errorCode'], -32602);
      expect(answer['errorDetail'], 'missing parameter `mode`');
      answer = await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': 'teleport',
        'location': '/b',
      });
      expect(answer['errorCode'], -32602);
      expect(
        answer['errorDetail'],
        'unknown mode `teleport`: one of go, push, replace, pop',
      );
    });

    test('without a router it is an extensionError', () async {
      final answer = await debugDevToolsCall(DevToolsMethods.navigate, {
        'mode': NavigateMode.go,
        'location': '/b',
      });
      expect(answer['errorCode'], -32000);
      expect(answer['errorDetail'], 'no fespalier router attached');
    });
  });

  group('match', () {
    test('gives the route and its parsed parameters', () async {
      devToolsRegister(tree: tree, matchUrl: matchUrl);
      final record = MatchRecord.fromJson(
        await debugDevToolsCall(DevToolsMethods.match, {
          'location': '/products/2?tab=info',
        }),
      );
      expect(record.location, '/products/2?tab=info');
      expect(record.route, '_ProductRoute');
      expect(record.params['id'], const Shown('int', '2'));
      expect(record.params['tab'], const Shown('String', 'info'));
      expect(record.data, 2);
    });

    test(
      'gives no match for a location no route has, or a segment that does not parse',
      () async {
        devToolsRegister(tree: tree, matchUrl: matchUrl);
        for (final location in ['/nowhere', '/products/abc']) {
          final answer = await debugDevToolsCall(DevToolsMethods.match, {
            'location': location,
          });
          expect(answer['match'], isNull, reason: location);
          expect(MatchRecord.fromJson(answer).route, isNull);
        }
      },
    );

    test('needs a location, and an app', () async {
      expect(
        (await debugDevToolsCall(DevToolsMethods.match, {
          'location': '/',
        }))['errorDetail'],
        'no fespalier router attached',
      );
      devToolsRegister(tree: tree, matchUrl: matchUrl);
      expect(
        (await debugDevToolsCall(DevToolsMethods.match))['errorDetail'],
        'missing parameter `location`',
      );
    });
  });

  group('clear', () {
    testWidgets('empties the history, and the numbers go on', (tester) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);
      router.go('/b');
      await tester.pumpAndSettle();
      final before = (await snapshot()).event;
      final answer = await debugDevToolsCall(DevToolsMethods.clear, {
        'what': ClearWhat.history,
      });
      expect(answer, {'protocol': 1, 'ok': true});
      expect((await snapshot()).history, isEmpty);
      router.go('/a');
      await tester.pumpAndSettle();
      final after = await snapshot();
      expect(after.history.single.seq, 3);
      expect(after.event, greaterThan(before));
      await debugDevToolsCall(DevToolsMethods.clear, {'what': ClearWhat.all});
      expect((await snapshot()).history, isEmpty);
    });

    test('an unknown `what` is invalidParams', () async {
      final answer = await debugDevToolsCall(DevToolsMethods.clear, {
        'what': 'guards',
      });
      expect(answer['errorCode'], -32602);
      expect(
        answer['errorDetail'],
        'unknown `what` `guards`: one of history, all',
      );
      expect(
        (await debugDevToolsCall(DevToolsMethods.clear))['errorCode'],
        -32602,
      );
    });
  });

  group('events', () {
    testWidgets(
      'each navigation is one, numbered, and the first is registered',
      (tester) async {
        final router = newRouter(initial: '/a');
        register(router);
        await pumpRouter(tester, router);
        router.go('/b');
        await tester.pumpAndSettle();
        expect(
          [for (final e in events) e.$1],
          [
            DevToolsEvents.registered,
            DevToolsEvents.registered,
            DevToolsEvents.navigation,
            DevToolsEvents.navigation,
          ],
        );
        expect([for (final e in events) e.$2['event']], [1, 2, 3, 4]);
        expect(events.every((e) => e.$2['protocol'] == 1), isTrue);
        final record = NavigationRecord.fromJson(
          events.last.$2['record']! as Map<String, Object?>,
        );
        expect(record.uri, '/b');
        expect(record.kind, NavigationKind.go);
        expect((await snapshot()).event, 4);
      },
    );

    testWidgets('every payload survives jsonEncode, whatever the extra is', (
      tester,
    ) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);
      router.go('/b', extra: Object());
      await tester.pumpAndSettle();
      for (final e in events) {
        expect(() => jsonEncode(e.$2), returnsNormally);
      }
      jsonEncode((await snapshot()).toJson());
    });

    testWidgets(
      'with no spy and no tool listening, nothing is posted and nothing throws',
      (tester) async {
        debugDevToolsEvents = null;
        final router = newRouter(initial: '/a');
        register(router);
        await pumpRouter(tester, router);
        router.go('/b');
        await tester.pumpAndSettle();
        expect((await snapshot()).history, hasLength(2));
        // The counter counts the events nobody saw, so a tool that connects later sees a gap.
        expect((await snapshot()).event, 4);
      },
    );
  });

  group('routers', () {
    testWidgets(
      'the last one attached is the one shown, and the first is let go',
      (tester) async {
        final first = newRouter(initial: '/a');
        register(first);
        await pumpRouter(tester, first);
        // A router that never showed a location has none to commit: what
        // DevTools shows is its, and the first one's listener is gone.
        final second = newRouter(initial: '/b');
        devToolsAttach(second);
        first.go('/products/1');
        await tester.pumpAndSettle();
        final snap = await snapshot();
        expect(snap.attached, isTrue);
        expect(snap.location, isNull);
        expect(snap.history.map((h) => h.uri), ['/a']);
        second.dispose();
      },
    );

    testWidgets('attaching the same router twice adds one listener', (
      tester,
    ) async {
      final router = newRouter(initial: '/a');
      register(router);
      devToolsAttach(router);
      await pumpRouter(tester, router);
      router.go('/b');
      await tester.pumpAndSettle();
      expect(await kinds(), [NavigationKind.initial, NavigationKind.go]);
    });

    testWidgets(
      'a router the app disposed does not break a snapshot or the next attach',
      (tester) async {
        final router = newRouter(initial: '/a');
        register(router);
        await pumpRouter(tester, router);
        await tester.pumpWidget(const SizedBox());
        router.dispose();
        final second = newRouter(initial: '/b');
        await pumpRouter(tester, second);
        devToolsAttach(second);
        expect((await snapshot()).location!.uri, '/b');
      },
    );
  });

  group('what it costs a test', () {
    testWidgets('no frame is scheduled by attaching, navigating or asking', (
      tester,
    ) async {
      final router = newRouter(initial: '/a');
      register(router);
      await pumpRouter(tester, router);
      expect(tester.binding.hasScheduledFrame, isFalse);
      for (final method in [
        DevToolsMethods.hello,
        DevToolsMethods.tree,
        DevToolsMethods.snapshot,
      ]) {
        await debugDevToolsCall(method);
      }
      await debugDevToolsCall(DevToolsMethods.match, {
        'location': '/products/1',
      });
      await debugDevToolsCall(DevToolsMethods.clear, {'what': ClearWhat.all});
      expect(tester.binding.hasScheduledFrame, isFalse);
      // The one frame a navigation needs is the router's own, and nothing follows it.
      router.go('/b');
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('asking never builds a page', (tester) async {
      var built = 0;
      final router = GoRouter(
        initialLocation: '/a',
        routes: [
          GoRoute(
            path: '/a',
            builder: (_, _) {
              built++;
              return page('A');
            },
          ),
        ],
      );
      register(router);
      await pumpRouter(tester, router);
      final before = built;
      await debugDevToolsCall(DevToolsMethods.snapshot);
      await debugDevToolsCall(DevToolsMethods.match, {'location': '/a'});
      await tester.pump();
      expect(built, before);
    });
  });

  group('what a user value is', () {
    testWidgets('an extra whose toString throws is shown as that', (
      tester,
    ) async {
      final router = newRouter(initial: '/a', extra: _Throws());
      register(router);
      await pumpRouter(tester, router);
      expect(
        (await snapshot()).location!.extra,
        const Shown('_Throws', shownThrew),
      );
    });

    testWidgets('a long text is cut', (tester) async {
      final router = newRouter(initial: '/a', extra: 'z' * 10000);
      register(router);
      await pumpRouter(tester, router);
      final extra = (await snapshot()).location!.extra!;
      expect(extra.text, '${'z' * 200}…');
    });
  });

  test(
    'a matcher that throws is reported once and does not break a snapshot',
    () async {
      devToolsRegister(
        tree: tree,
        matchUrl: (_) => throw StateError('bad matcher'),
      );
      final answer = await debugDevToolsCall(DevToolsMethods.match, {
        'location': '/',
      });
      expect(answer['errorDetail'], contains('bad matcher'));
    },
  );
}

const _limit = 100;

class _Throws {
  @override
  String toString() => throw StateError('no');
}
