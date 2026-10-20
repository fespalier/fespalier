// A hot reload swaps in the regenerated route table of a generated app (since 0.19.0): the
// router host's reassemble (`reloadRoutes`), the rules of the swap, and what a page keeps. The
// reload is the test's own call (`reassembleApplication`, as `r` makes it); nothing waits on a
// timer or the network. The generated code's `_AppRoutesReload` is `_Reload` here.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/routes_reload.dart' show keptChangedMessage;
import 'package:fespalier/startup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/floor.dart';

String? _noRedirect(BuildContext context, GoRouterState state) => null;

/// What a generated file gives a router: its version and kept fields as it reads them now, and the
/// routes a reload builds (`table`). A test changes them between two reloads, as an edit does.
final class _Reload extends RoutesReload {
  _Reload(
    List<RouteBase> routes, {
    String version = 'v1',
    Map<String, String> kept = const {},
    this.redirect,
  }) : table = routes,
       fileVersion = version,
       fileKept = kept,
       super(RoutingConfig(routes: routes, redirect: redirect ?? _noRedirect));

  String fileVersion;
  Map<String, String> fileKept;
  List<RouteBase> table;
  int rebuilds = 0;

  /// What the generated `_reload` does beside the rebuild: it makes its deferred list again and
  /// registers it (since 0.20.0). A test sets it.
  VoidCallback? onRebuild;

  /// The app's top-level redirect, which a rebuild keeps.
  final GoRouterRedirect? redirect;

  /// The next [rebuild] throws this, once.
  Object? failOnce;

  @override
  String get version => fileVersion;

  @override
  Map<String, String> get kept => fileKept;

  @override
  RoutingConfig rebuild(GoRouter router) {
    rebuilds++;
    final failure = failOnce;
    if (failure != null) {
      failOnce = null;
      throw failure;
    }
    onRebuild?.call();
    return RoutingConfig(routes: table, redirect: redirect ?? _noRedirect);
  }

  @override
  Widget notFound(Uri uri) => Text('nothing at ${uri.path}');
}

/// The router the generated `AppRoutes.router()` makes around [reload]: go_router on its routing
/// config, with the not-found page, and the table following the router.
GoRouter _routerOf(_Reload reload, {String initialLocation = '/'}) {
  final router = GoRouter.routingConfig(
    routingConfig: reload,
    initialLocation: initialLocation,
    overridePlatformDefaultLocation: true,
    errorBuilder: (_, state) => reload.notFound(state.uri),
  );
  reload.follow(router);
  return router;
}

Widget app(GoRouter router) => MaterialApp.router(routerConfig: router);

/// A hot reload: the framework's reassemble of the app, then the frame it leads to.
Future<void> hotReload(WidgetTester tester) async {
  unawaited(tester.binding.reassembleApplication());
  await pumpNavigation(tester);
}

/// A page with a count the user taps: the state a swap must keep.
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('count $count'),
  );
}

GoRoute _a() => GoRoute(path: '/a', builder: (_, _) => const _Counter());

GoRoute _b() => GoRoute(path: '/b', builder: (_, _) => const Text('B page'));

void main() {
  testWidgets('a regeneration swaps the routes and the page keeps its state', (
    tester,
  ) async {
    final reload = _Reload([_a()]);
    final router = _routerOf(reload, initialLocation: '/a');
    await tester.pumpWidget(StartupGate(router: () => router, app: app));
    await tester.tap(find.text('count 0'));
    await tester.pump();
    expect(find.text('count 1'), findsOneWidget);

    reload.fileVersion = 'v2';
    reload.table = [_a(), _b()];
    await hotReload(tester);

    expect(reload.rebuilds, 1);
    expect(find.text('count 1'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/a');

    router.go('/b');
    await pumpNavigation(tester);
    expect(find.text('B page'), findsOneWidget);
  });

  testWidgets('a removed route shows not-found', (tester) async {
    final reload = _Reload([_a(), _b()]);
    final router = _routerOf(reload, initialLocation: '/b');
    await tester.pumpWidget(StartupGate(router: () => router, app: app));
    expect(find.text('B page'), findsOneWidget);

    reload.fileVersion = 'v2';
    reload.table = [_a()];
    await hotReload(tester);

    expect(reload.rebuilds, 1);
    expect(find.text('nothing at /b'), findsOneWidget);
  });

  testWidgets('an unchanged file swaps nothing', (tester) async {
    final reload = _Reload([_a()]);
    final router = _routerOf(reload);
    await tester.pumpWidget(StartupGate(router: () => router, app: app));
    var notified = 0;
    router.routerDelegate.addListener(() => notified++);

    await hotReload(tester);
    await hotReload(tester);

    expect(reload.rebuilds, 0);
    expect(notified, 0);
  });

  testWidgets('a changed kept field keeps the old routes and says so once', (
    tester,
  ) async {
    final printed = <String?>[];
    final saved = debugPrint;
    // Restored in a `finally`: the framework checks the foundation variables before a tearDown.
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    try {
      final reload = _Reload([_a()], kept: {'_data1': 'x'});
      final router = _routerOf(reload);
      await tester.pumpWidget(StartupGate(router: () => router, app: app));

      reload.fileVersion = 'v2';
      reload.fileKept = {'_data1': 'y'};
      reload.table = [_a(), _b()];
      await hotReload(tester);

      expect(reload.rebuilds, 0);
      expect(printed.where((m) => m == keptChangedMessage), hasLength(1));

      // The same version again: nothing is compared, so nothing is printed.
      final before = printed.length;
      await hotReload(tester);
      expect(printed, hasLength(before));
      expect(reload.rebuilds, 0);

      // The old routes stay: /b is not one of them.
      router.go('/b');
      await pumpNavigation(tester);
      expect(find.text('nothing at /b'), findsOneWidget);
    } finally {
      debugPrint = saved;
    }
  });

  testWidgets('an added or removed kept field still swaps', (tester) async {
    final reload = _Reload([_a()], kept: {'a': '1'});
    final router = _routerOf(reload);
    await tester.pumpWidget(StartupGate(router: () => router, app: app));

    reload.fileVersion = 'v2';
    reload.fileKept = {'a': '1', 'b': '2'};
    reload.table = [_a(), _b()];
    await hotReload(tester);
    expect(reload.rebuilds, 1);

    reload.fileVersion = 'v3';
    reload.fileKept = {'b': '2'};
    reload.table = [_a()];
    await hotReload(tester);
    expect(reload.rebuilds, 2);
  });

  testWidgets('a page in a layout keeps its state', (tester) async {
    final keys = ShellKeys();
    // A layout as the generated code makes one: its page is keyed by its restoration id.
    List<RouteBase> table({bool more = false}) => [
      ShellRoute(
        navigatorKey: keys.navigator('layout:/'),
        pageBuilder: (context, state, child) =>
            layoutPage(context, state, 'layout:/', Scaffold(body: child)),
        routes: [_a(), if (more) _b()],
      ),
    ];

    final reload = _Reload(table());
    final router = _routerOf(reload, initialLocation: '/a');
    await tester.pumpWidget(StartupGate(router: () => router, app: app));
    await tester.tap(find.text('count 0'));
    await tester.pump();
    await tester.tap(find.text('count 1'));
    await tester.pump();
    expect(find.text('count 2'), findsOneWidget);

    reload.fileVersion = 'v2';
    reload.table = table(more: true);
    await hotReload(tester);

    expect(reload.rebuilds, 1);
    expect(find.text('count 2'), findsOneWidget);
  });

  testWidgets(
    'the tab on screen keeps its stack, and the others do from go_router 18.1.1',
    (tester) async {
      final keys = ShellKeys();
      GoRoute tab(String name) => GoRoute(
        path: '/$name',
        builder: (_, _) => Text('$name root'),
        routes: [
          GoRoute(path: 'child', builder: (_, _) => Text('$name child')),
        ],
      );
      List<RouteBase> tabs({bool more = false}) => [
        StatefulShellRoute.indexedStack(
          key: keys.shell('tabs:/'),
          pageBuilder: (context, state, shell) =>
              layoutPage(context, state, 'tabs:/', Scaffold(body: shell)),
          branches: [
            StatefulShellBranch(
              navigatorKey: keys.navigator('tab:a'),
              routes: [tab('a')],
            ),
            StatefulShellBranch(
              navigatorKey: keys.navigator('tab:b'),
              routes: [tab('b')],
            ),
          ],
        ),
        if (more) GoRoute(path: '/c', builder: (_, _) => const Text('C page')),
      ];

      final reload = _Reload(tabs());
      final router = _routerOf(reload, initialLocation: '/b/child');
      // The hooks an observe.dart gives every page: what each one saw, in order.
      final seen = <String>[];
      observeAttach(
        router,
        (uri) => [
          RouteHooks(
            'observe.dart',
            onEnter: (ref, _) => seen.add('enter ${uri.path}'),
            onLeave: (ref) => seen.add('leave ${uri.path}'),
            onFocus: (ref) => seen.add('focus ${uri.path}'),
          ),
        ],
      );
      await tester.pumpWidget(StartupGate(router: () => router, app: app));
      expect(find.text('b child'), findsOneWidget);
      router.go('/a/child');
      await pumpNavigation(tester);
      expect(find.text('a child'), findsOneWidget);

      seen.clear();
      reload.fileVersion = 'v2';
      reload.table = tabs(more: true);
      await hotReload(tester);
      expect(reload.rebuilds, 1);
      expect(find.text('a child'), findsOneWidget);
      // A tab that starts over runs the onLeave of the page it held; one that keeps its stack
      // does not.
      expect(seen, beforeGoRouter1811 ? ['leave /b/child'] : isEmpty);

      keys.shell('tabs:/').currentState!.goBranch(1);
      await pumpNavigation(tester);
      // Before go_router 18.1.1 only the branch on screen survives a new table (its state is
      // keyed by the StatefulShellBranch, which the new table makes again); from 18.1.1 a
      // branch that was loaded keeps its stack (keyed by its navigator key, which is reused).
      if (beforeGoRouter1811) {
        expect(find.text('b root'), findsOneWidget);
        expect(find.text('b child'), findsNothing);
      } else {
        expect(find.text('b child'), findsOneWidget);
        expect(find.text('b root'), findsNothing);
        expect(router.routerDelegate.currentConfiguration.uri.path, '/b/child');
      }
    },
  );

  testWidgets('a pushed page survives', (tester) async {
    GoRoute pushed() =>
        GoRoute(path: '/p', builder: (_, _) => const Text('P page'));
    final reload = _Reload([_a(), pushed()]);
    final router = _routerOf(reload, initialLocation: '/a');
    await tester.pumpWidget(StartupGate(router: () => router, app: app));
    unawaited(router.push('/p'));
    await pumpNavigation(tester);
    expect(find.text('P page'), findsOneWidget);

    reload.fileVersion = 'v2';
    reload.table = [_a(), _b(), pushed()];
    await hotReload(tester);

    expect(reload.rebuilds, 1);
    expect(find.text('P page'), findsOneWidget);
  });

  testWidgets('a push inside a layout is kept, except on go_router 17', (
    tester,
  ) async {
    final keys = ShellKeys();
    List<RouteBase> table() => [
      ShellRoute(
        navigatorKey: keys.navigator('layout:/'),
        pageBuilder: (context, state, child) =>
            layoutPage(context, state, 'layout:/', Scaffold(body: child)),
        routes: [
          _a(),
          GoRoute(path: '/q', builder: (_, _) => const Text('Q page')),
        ],
      ),
    ];

    final reload = _Reload(table());
    final router = _routerOf(reload, initialLocation: '/a');
    await tester.pumpWidget(StartupGate(router: () => router, app: app));
    unawaited(router.push('/q'));
    await pumpNavigation(tester);
    expect(find.text('Q page'), findsOneWidget);

    reload.fileVersion = 'v2';
    reload.table = table();
    await hotReload(tester);

    expect(reload.rebuilds, 1);
    // go_router 17 drops a page pushed inside a layout when the routes are parsed again; 18 keeps it.
    if (onGoRouter17) {
      expect(find.text('Q page'), findsNothing);
    } else {
      expect(find.text('Q page'), findsOneWidget);
    }
  });

  testWidgets('leave() is not asked for a page that stays', (tester) async {
    var asked = 0;
    List<RouteBase> table() => [
      GoRoute(
        path: '/a',
        builder: (_, _) => const _Counter(),
        onExit: (context, state) =>
            leaveExit(context, state, 'x/leave.dart', (_, _) {
              asked++;
              return false;
            }),
      ),
      _b(),
    ];

    final reload = _Reload(table());
    final router = _routerOf(reload, initialLocation: '/a');
    await tester.pumpWidget(StartupGate(router: () => router, app: app));

    reload.fileVersion = 'v2';
    reload.table = table();
    await hotReload(tester);
    expect(reload.rebuilds, 1);
    expect(asked, 0);
    expect(find.text('count 0'), findsOneWidget);

    // A navigation away is asked, and the page stays.
    router.go('/b');
    await pumpNavigation(tester);
    expect(asked, 1);
    expect(find.text('count 0'), findsOneWidget);
  });

  group('a restore that is not a swap still asks leave()', () {
    final asked = <String>[];
    var redirectOn = false;

    setUp(() {
      asked.clear();
      redirectOn = false;
    });

    // A page `x` whose leave() always refuses, between two plain ones.
    GoRoute refusing() => GoRoute(
      path: '/x',
      onExit: (context, state) =>
          leaveExit(context, state, 'x/leave.dart', (_, _) {
            asked.add('x');
            return false;
          }),
      builder: (_, _) => const Text('x page'),
    );

    GoRoute plain(String path, String label) =>
        GoRoute(path: path, builder: (_, _) => Text(label));

    Future<GoRouter> boot(WidgetTester tester) async {
      final reload = _Reload(
        [
          plain('/y', 'y page'),
          refusing(),
          plain('/z', 'z page'),
          plain('/login', 'login page'),
        ],
        redirect: (context, state) =>
            redirectOn && state.uri.path != '/login' ? '/login' : null,
      );
      final router = _routerOf(reload, initialLocation: '/y');
      await tester.pumpWidget(StartupGate(router: () => router, app: app));
      unawaited(router.push<void>('/x'));
      await pumpNavigation(tester);
      await tester.pumpAndSettle();
      unawaited(router.push<void>('/z'));
      await pumpNavigation(tester);
      await tester.pumpAndSettle();
      expect(find.text('z page'), findsOneWidget);
      return router;
    }

    testWidgets('two pops in one frame ask the page under the first', (
      tester,
    ) async {
      final router = await boot(tester);

      router.pop(); // z goes: nothing to ask
      router.pop(); // x is asked, and refuses
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(asked, ['x']);
      expect(find.text('x page'), findsOneWidget);
    });

    testWidgets(
      'a pop and a refresh that redirects in one frame ask the page',
      (tester) async {
        final router = await boot(tester);

        router.pop(); // z goes
        redirectOn = true; // a session ends
        router.refresh();
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();

        expect(asked, ['x']);
      },
    );
  });

  testWidgets(
    'a rebuild that throws is reported, and the next reload tries again',
    (tester) async {
      final reload = _Reload([_a()]);
      final router = _routerOf(reload, initialLocation: '/a');
      await tester.pumpWidget(StartupGate(router: () => router, app: app));
      await tester.tap(find.text('count 0'));
      await tester.pump();

      reload.fileVersion = 'v2';
      reload.table = [_a(), _b()];
      reload.failOnce = StateError('the routes do not build');
      await hotReload(tester);

      expect(tester.takeException(), isA<StateError>());
      expect(reload.rebuilds, 1);
      expect(find.text('count 1'), findsOneWidget);
      router.go('/b');
      await pumpNavigation(tester);
      expect(find.text('nothing at /b'), findsOneWidget);
      router.go('/a');
      await pumpNavigation(tester);

      // The same version again: the routes of the failed reload are tried again, and swap.
      await hotReload(tester);
      expect(tester.takeException(), isNull);
      expect(reload.rebuilds, 2);
      router.go('/b');
      await pumpNavigation(tester);
      expect(find.text('B page'), findsOneWidget);

      // Swapped: the version is the one in use now, so another reload does nothing.
      await hotReload(tester);
      expect(reload.rebuilds, 2);
    },
  );

  testWidgets('a router no table follows is left alone', (tester) async {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
    );
    await tester.pumpWidget(StartupGate(router: () => router, app: app));

    await hotReload(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a table that overrides notFound alone shows it for a failed '
      'guard, and the failure is reported', (tester) async {
    final reload = _Reload([
      GoRoute(path: '/', builder: (_, _) => const Text('HOME')),
      GoRoute(
        path: '/boom',
        redirect: (_, _) => runRedirect(() => throw StateError('boom')),
        builder: (_, _) => const Text('BOOM'),
      ),
    ]);
    final router = GoRouter.routingConfig(
      routingConfig: reload,
      initialLocation: '/',
      overridePlatformDefaultLocation: true,
      errorBuilder: (context, state) => reload.errorPage(context, state),
    );
    reload.follow(router);
    await tester.pumpWidget(StartupGate(router: () => router, app: app));

    router.go('/boom');
    await tester.pumpAndSettle();

    expect(find.text('nothing at /boom'), findsOneWidget);
    expect(tester.takeException(), isA<StateError>());
  });

  test(
    'ShellKeys gives the same key for the same id, and another for another',
    () {
      final keys = ShellKeys();
      final navigator = keys.navigator('layout:/');
      expect(identical(keys.navigator('layout:/'), navigator), isTrue);
      expect(identical(keys.navigator('tab:a'), navigator), isFalse);

      final shell = keys.shell('layout:/');
      expect(identical(keys.shell('layout:/'), shell), isTrue);
      expect(identical(keys.shell('tab:a'), shell), isFalse);

      // A new mount's keys are new keys.
      expect(identical(ShellKeys().navigator('layout:/'), navigator), isFalse);
    },
  );

  test('the message a refused swap prints is the one the docs quote', () {
    expect(
      keptChangedMessage,
      'fespalier: the regenerated routes change a provider, a deferred library or a router setting that a hot reload keeps, so the app keeps its old routes: hot restart (R) to use the new ones',
    );
  });

  testWidgets(
    'a swap that adds a deferred route registers it, and a loaded one stays loaded',
    (tester) async {
      final calls = <String>[];
      DeferredLibrary lib(String f) =>
          DeferredLibrary(() async => calls.add(f), f, loadsInFakeAsync: true);
      final big = lib('big/page.dart');
      final zoo = lib('zoo/page.dart');
      var deferred = [big];
      DeferredLibrary.register(deferred);
      await tester.runAsync(() => DeferredLibrary.loadAll(deferred));

      final reload = _Reload([_a()], kept: {'_libBig': 'b1'})
        ..onRebuild = () => DeferredLibrary.register(deferred);
      final router = _routerOf(reload, initialLocation: '/a');
      await tester.pumpWidget(StartupGate(router: () => router, app: app));

      reload.fileVersion = 'v2';
      reload.fileKept = {'_libBig': 'b1', '_libZoo': 'z1'};
      reload.table = [_a(), _b()];
      deferred = [big, zoo];
      await hotReload(tester);

      expect(reload.rebuilds, 1);
      expect(big.isLoaded, isTrue);
      expect(zoo.isLoaded, isFalse);
      expect(DeferredLibrary.anyPending, isTrue);

      await tester.runAsync(() => DeferredLibrary.loadAll(deferred));
      expect(calls, ['big/page.dart', 'zoo/page.dart']);
      expect(DeferredLibrary.anyPending, isFalse);
    },
  );

  testWidgets(
    'a swap that removes a deferred route leaves its library registered until a restart',
    (tester) async {
      final calls = <String>[];
      DeferredLibrary lib(String f) =>
          DeferredLibrary(() async => calls.add(f), f, loadsInFakeAsync: true);
      final yak = lib('yak/page.dart');
      final big2 = lib('big/page.dart');
      var deferred = [yak];
      DeferredLibrary.register(deferred);

      final reload = _Reload([_a()], kept: {'_libYak': 'y1'})
        ..onRebuild = () => DeferredLibrary.register(deferred);
      final router = _routerOf(reload, initialLocation: '/a');
      await tester.pumpWidget(StartupGate(router: () => router, app: app));
      expect(DeferredLibrary.anyPending, isTrue);

      reload.fileVersion = 'v2';
      reload.fileKept = {};
      deferred = [big2];
      await hotReload(tester);
      expect(reload.rebuilds, 1);

      // The list is the new one: only its library loads. `yak` is still registered (the limit).
      await tester.runAsync(() => DeferredLibrary.loadAll(deferred));
      expect(calls, ['big/page.dart']);
      expect(
        DeferredLibrary.anyPending,
        isTrue,
        reason: 'a removed route stays registered',
      );

      await tester.runAsync(() => DeferredLibrary.loadAll());
      expect(calls, ['big/page.dart', 'yak/page.dart']);
      expect(DeferredLibrary.anyPending, isFalse);
    },
  );
}
