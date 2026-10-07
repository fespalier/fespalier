// leave.dart (since 0.11.0): `leaveExit` is a GoRoute's `onExit`, `leaveScope` the wrapper of its
// page. What is asked, what is not, and what the back gestures do. The routers here are what
// the generator writes for a folder with a leave.dart, by hand.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/deferred_page.dart' deferred as deferred_page;
import 'support/floor.dart';

/// What `leave()` was asked, in order: `label` or `label dirty` (the page's `isDirty`).
final List<String> asked = [];

/// What each `leave()` answers; replaced by a test.
LeaveResult Function(String label, PageLeave page) answer = (_, _) => true;

/// The root navigator's key: some routes go on it, under a shell.
final rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// A [LeaveSource] a page registers.
class FakeSource extends ChangeNotifier implements LeaveSource {
  FakeSource(this.name, {bool dirty = false, this.keeps = false})
    : _dirty = dirty;

  final String name;
  final bool keeps;
  bool _dirty;
  final List<String> calls = [];

  set dirty(bool value) {
    _dirty = value;
    notifyListeners();
  }

  @override
  bool get isDirty => _dirty;

  @override
  bool get canKeep => keeps;

  @override
  FutureOr<void> keep() {
    calls.add('keep');
  }

  @override
  void discard() {
    calls.add('discard');
  }
}

/// Registers [source] in the page's `LeaveScope` while it is on screen, as a form does.
class Registrar extends StatefulWidget {
  const Registrar(this.source, {super.key, required this.child});

  final LeaveSource source;
  final Widget child;

  @override
  State<Registrar> createState() => _RegistrarState();
}

class _RegistrarState extends State<Registrar> {
  VoidCallback? _unregister;

  @override
  void initState() {
    super.initState();
    // During build, like `useActionForm`'s hook.
    _unregister = LeaveScope.maybeOf(context)?.register(widget.source);
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The sources the pages register, by page label; a test sets them up.
final Map<String, FakeSource> sources = {};

/// The system-back handlers the pages register in their scope, by page label.
final Map<String, bool Function()> backs = {};

/// Whether the guarded tab's route redirects out of the shell.
bool guardOn = false;

/// Registers [handler] with the page's `LeaveScope.onBack`.
class BackRegistrar extends StatefulWidget {
  const BackRegistrar(this.handler, {super.key, required this.child});

  final bool Function() handler;
  final Widget child;

  @override
  State<BackRegistrar> createState() => _BackRegistrarState();
}

class _BackRegistrarState extends State<BackRegistrar> {
  VoidCallback? _unregister;

  @override
  void initState() {
    super.initState();
    _unregister = LeaveScope.maybeOf(context)?.onBack(widget.handler);
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Widget page(String label) => Scaffold(body: Center(child: Text(label)));

/// What the generator writes for a folder with a leave.dart: `onExit` and the page wrapper.
GoRoute leaving(
  String path,
  String label, {
  List<RouteBase> routes = const [],
  String Function(GoRouterState state)? labelOf,
}) {
  return GoRoute(
    path: path,
    onExit: (context, state) => leaveExit(
      context,
      state,
      '$label/leave.dart',
      (ref, pageLeave) => leaveWithParams<void>(() {}, (_) {
        final l = labelOf?.call(state) ?? label;
        asked.add(pageLeave.isDirty ? '$l dirty' : l);
        return answer(l, pageLeave);
      }),
    ),
    pageBuilder: (context, state) {
      final l = labelOf?.call(state) ?? label;
      var body = page(l);
      final source = sources[l];
      if (source != null) body = Registrar(source, child: body);
      final back = backs[l];
      if (back != null) body = BackRegistrar(back, child: body);
      return MaterialPage<void>(
        key: state.pageKey,
        child: leaveScope(state, body),
      );
    },
    routes: routes,
  );
}

GoRoute plain(String path, String label) => GoRoute(
  path: path,
  pageBuilder: (context, state) =>
      MaterialPage<void>(key: state.pageKey, child: page(label)),
);

GoRouter router({String initial = '/a', String? Function(Uri uri)? redirect}) {
  return GoRouter(
    initialLocation: initial,
    navigatorKey: rootKey,
    redirect: redirect == null ? null : (context, state) => redirect(state.uri),
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => shell,
        branches: [
          StatefulShellBranch(
            routes: [
              leaving(
                '/a',
                'a',
                routes: [
                  leaving(
                    ':id',
                    'a/id',
                    labelOf: (s) => 'a/${s.pathParameters['id']}',
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(routes: [leaving('/b', 'b')]),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/g',
                redirect: (context, state) => guardOn ? '/y' : null,
                pageBuilder: (context, state) =>
                    MaterialPage<void>(key: state.pageKey, child: page('g')),
              ),
            ],
          ),
        ],
      ),
      leaving('/x', 'x'),
      ShellRoute(
        parentNavigatorKey: rootKey,
        builder: (context, state, child) => child,
        routes: [leaving('/s', 's')],
      ),
      plain('/y', 'y'),
      plain('/z', 'z'),
      GoRoute(
        path: '/rm/:id',
        onExit: (context, state) =>
            leaveExit(context, state, 'rm/leave.dart', (ref, pageLeave) {
              asked.add(
                'rm/${state.pathParameters['id']}'
                '${pageLeave.isDirty ? ' dirty' : ''}',
              );
              return answer('rm', pageLeave);
            }),
        pageBuilder: (context, state) {
          var body = page('rm ${state.pathParameters['id']}');
          final source = sources['rm'];
          if (source != null) body = Registrar(source, child: body);
          return remountPage(
            context,
            state,
            remountKey(state, Remount.onLocation, const ['id']),
            leaveScope(state, body),
          );
        },
      ),
    ],
  );
}

/// The reports `FlutterError.reportError` made while [body] ran.
Future<List<FlutterErrorDetails>> reported(Future<void> Function() body) async {
  final seen = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = seen.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return seen;
}

Future<GoRouter> boot(
  WidgetTester tester, {
  String initial = '/a',
  String? Function(Uri uri)? redirect,
}) async {
  asked.clear();
  sources.clear();
  backs.clear();
  guardOn = false;
  answer = (_, _) => true;
  final r = router(initial: initial, redirect: redirect);
  await pumpRouter(tester, r);
  return r;
}

String where(GoRouter r) =>
    r.routerDelegate.currentConfiguration.uri.toString();

/// A few frames and microtasks: go_router's pops answer in a microtask.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

/// The system's back button, as the engine sends it.
Future<void> systemBack(WidgetTester tester) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await settle(tester);
}

/// What the app asked the system to do (`SystemNavigator.pop`), recorded for the test.
List<String> recordSystemNavigator(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemNavigator.pop') calls.add(call.method);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

Future<void> push(WidgetTester tester, GoRouter r, String location) async {
  unawaited(r.push<void>(location));
  await settle(tester);
}

/// The browser's back or forward, as the engine sends it to the router.
Future<void> platformGo(
  WidgetTester tester,
  String location, {
  Object? state,
}) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    MethodCall('pushRouteInformation', {'location': location, 'state': state}),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await settle(tester);
}

/// Some `GoRouterState`, for a [PageLeave] a test builds itself.
Future<GoRouterState> anyState(WidgetTester tester) async {
  final r = router(initial: '/y');
  await pumpRouter(tester, r);
  return r.routerDelegate.state;
}

void main() {
  group('go, replace, pushReplacement', () {
    testWidgets('go away from a page that refuses keeps it', (tester) async {
      final r = await boot(tester, initial: '/x');
      answer = (_, _) => false;
      r.go('/y');
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
      expect(where(r), '/x');
    });

    testWidgets('go away from a page that allows it', (tester) async {
      final r = await boot(tester, initial: '/x');
      r.go('/y');
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('y'), findsOneWidget);
    });

    testWidgets('replace and pushReplacement ask the page they replace', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      answer = (_, _) => false;
      unawaited(r.pushReplacement<void>('/z'));
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
      answer = (_, _) => true;
      unawaited(r.pushReplacement<void>('/z'));
      await settle(tester);
      expect(asked, ['x', 'x']);
      expect(find.text('z'), findsOneWidget);

      await push(tester, r, '/x');
      answer = (_, _) => false;
      unawaited(r.replace<void>('/y'));
      await settle(tester);
      expect(find.text('x'), findsOneWidget);
      answer = (_, _) => true;
      unawaited(r.replace<void>('/y'));
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
      expect(asked, ['x', 'x', 'x', 'x']);
    });

    testWidgets(
      '/c/1 to /c/2 asks, and a nested page is asked before its parent',
      (tester) async {
        final r = await boot(tester);
        r.go('/a/1');
        await settle(tester);
        expect(
          asked,
          isEmpty,
          reason: 'a page that opens a page inside it stays',
        );
        r.go('/a/2');
        await settle(tester);
        expect(asked, ['a/1']);
        asked.clear();
        r.go('/y');
        await settle(tester);
        expect(asked, [
          'a/2',
          'a',
        ], reason: 'the deepest first, like go_router');
      },
    );

    testWidgets('one refusal stops the walk outwards', (tester) async {
      final r = await boot(tester);
      r.go('/a/1');
      await settle(tester);
      answer = (label, _) => label != 'a/1';
      r.go('/y');
      await settle(tester);
      expect(asked, ['a/1']);
      expect(where(r), '/a/1');
    });
  });

  group('pop', () {
    testWidgets('GoRouter.pop of a pushed page refuses and allows', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      answer = (_, _) => false;
      r.pop();
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
      answer = (_, _) => true;
      r.pop();
      await settle(tester);
      expect(asked, ['x', 'x']);
      expect(find.text('y'), findsOneWidget);
      expect(find.text('x'), findsNothing);
    });

    testWidgets('context.pop and Navigator.pop ask too', (tester) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      answer = (_, _) => false;
      tester.element(find.text('x')).pop();
      await settle(tester);
      expect(find.text('x'), findsOneWidget);
      Navigator.of(tester.element(find.text('x'))).pop();
      await settle(tester);
      expect(find.text('x'), findsOneWidget);
      expect(asked, ['x', 'x']);
      answer = (_, _) => true;
      Navigator.of(tester.element(find.text('x'))).pop();
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
    });

    testWidgets('a page pushed twice is two instances, asked one by one', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      sources['x'] = FakeSource('first', dirty: true);
      await push(tester, r, '/x');
      sources['x'] = FakeSource('second');
      await push(tester, r, '/x');
      answer = (_, _) => true;
      r.pop();
      await settle(tester);
      expect(asked, ['x'], reason: 'the second is clean');
      r.pop();
      await settle(tester);
      expect(asked, ['x', 'x dirty'], reason: 'the first has its own source');
      expect(find.text('y'), findsOneWidget);
    });
  });

  group('the back button', () {
    testWidgets('on a page that can pop it goes through PopScope and leave()', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      answer = (_, _) => false;
      await systemBack(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
      answer = (_, _) => true;
      await systemBack(tester);
      expect(asked, ['x', 'x']);
      expect(find.text('y'), findsOneWidget);
    });

    testWidgets('a clean form lets the back through, and leave() still asks', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      sources['x'] = FakeSource('form');
      await push(tester, r, '/x');
      answer = (_, _) => false;
      await systemBack(tester);
      expect(asked, [
        'x',
      ], reason: 'Navigator.pop asks go_router, which asks leave()');
      expect(find.text('x'), findsOneWidget);
      answer = (_, _) => true;
      await systemBack(tester);
      expect(find.text('y'), findsOneWidget);
    });

    testWidgets(
      'on the bottom page go_router asks leave(), and true closes the app',
      (tester) async {
        final closed = recordSystemNavigator(tester);
        await boot(tester, initial: '/x');
        answer = (_, _) => false;
        await systemBack(tester);
        expect(asked, ['x']);
        expect(closed, isEmpty);
        expect(find.text('x'), findsOneWidget);
        answer = (_, _) => true;
        await systemBack(tester);
        expect(asked, ['x', 'x']);
        expect(closed, ['SystemNavigator.pop']);
      },
    );

    testWidgets('the same in a tab: the page that is on top is asked', (
      tester,
    ) async {
      final closed = recordSystemNavigator(tester);
      final r = await boot(tester);
      r.go('/a/1');
      await settle(tester);
      answer = (label, _) => false;
      await systemBack(tester);
      expect(asked, ['a/1'], reason: 'the leaf, not the page below it');
      expect(closed, isEmpty);
      expect(find.text('a/1'), findsOneWidget);
      answer = (_, _) => true;
      await systemBack(tester);
      expect(closed, isEmpty);
      expect(find.text('a'), findsOneWidget);
      expect(where(r), '/a');
    });
  });

  group('what is not asked', () {
    testWidgets(
      'a tab switch is not asked, leaving the layout asks the active tab',
      (tester) async {
        final r = await boot(tester);
        answer = (_, _) => false;
        StatefulNavigationShell.of(tester.element(find.text('a'))).goBranch(1);
        await settle(tester);
        expect(find.text('b'), findsOneWidget);
        StatefulNavigationShell.of(tester.element(find.text('b'))).goBranch(0);
        await settle(tester);
        expect(find.text('a'), findsOneWidget);
        r.go('/b');
        await settle(tester);
        expect(find.text('b'), findsOneWidget);
        expect(
          asked,
          isEmpty,
          reason: 'a switch parks the page; it does not go',
        );
        r.go('/y');
        await settle(tester);
        expect(asked, ['b'], reason: 'only the active tab: a is parked');
        expect(where(r), '/b');
      },
    );

    testWidgets('a tab switch parks the page with its children too', (
      tester,
    ) async {
      final r = await boot(tester);
      r.go('/a/1');
      await settle(tester);
      answer = (_, _) => false;
      r.go('/b');
      await settle(tester);
      expect(find.text('b'), findsOneWidget);
      expect(asked, isEmpty);
    });

    testWidgets('a query-only change is not asked', (tester) async {
      final r = await boot(tester);
      answer = (_, _) => false;
      r.go('/a?page=2');
      await settle(tester);
      expect(where(r), '/a?page=2');
      r.go('/a/1?tab=x');
      await settle(tester);
      r.go('/a/1?tab=y');
      await settle(tester);
      expect(where(r), '/a/1?tab=y');
      expect(asked, isEmpty);
    });

    testWidgets('a page that has no leave.dart goes without asking', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      r.go('/z');
      await settle(tester);
      expect(find.text('z'), findsOneWidget);
      expect(asked, isEmpty);
    });
  });

  group('the answer', () {
    testWidgets('a synchronous answer adds no microtask and no Future', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/x');
      final context = tester.element(find.text('x'));
      final state = r.routerDelegate.state;
      // The `Ref` is a throwaway provider's, and Riverpod schedules its own microtasks for a
      // provider it creates and disposes (it does for a `refGuard` too): what must hold is that
      // none of them is fespalier's, and that the answer is the very bool.
      final origins = <String>[];
      final spec = ZoneSpecification(
        scheduleMicrotask: (self, parent, zone, f) {
          final frames = StackTrace.current.toString().split('\n');
          origins.add(
            frames.firstWhere(
              (f) =>
                  f.trim().isNotEmpty &&
                  !f.contains('<asynchronous') &&
                  !f.contains('(dart:') &&
                  !f.contains('leave_test.dart'),
              orElse: () => 'unknown',
            ),
          );
          parent.scheduleMicrotask(zone, f);
        },
      );
      late final LeaveResult yes;
      runZoned(
        () => yes = leaveExit(context, state, 'x/leave.dart', (_, _) => true),
        zoneSpecification: spec,
      );
      expect(yes, isA<bool>());
      expect(yes, isTrue);
      late final LeaveResult no;
      runZoned(
        () => no = leaveExit(context, state, 'x/leave.dart', (_, _) => false),
        zoneSpecification: spec,
      );
      expect(no, isA<bool>());
      expect(no, isFalse);
      expect(origins, isNotEmpty, reason: 'the probe sees the microtasks');
      expect(
        origins.where(
          (o) =>
              !o.contains('package:riverpod') &&
              !o.contains('package:flutter_riverpod'),
        ),
        isEmpty,
        reason: 'every microtask is Riverpod\'s own: $origins',
      );
    });

    testWidgets('an async prompt waits, and two asks share it', (tester) async {
      final r = await boot(tester, initial: '/x');
      final prompt = Completer<bool>();
      answer = (_, _) => prompt.future;
      r.go('/y');
      await settle(tester);
      expect(find.text('x'), findsOneWidget);
      r.go('/z');
      await settle(tester);
      unawaited(r.routerDelegate.popRoute());
      await settle(tester);
      expect(asked, ['x'], reason: 'one prompt at a time');
      prompt.complete(false);
      await settle(tester);
      expect(find.text('x'), findsOneWidget);
      // The next ask is a new prompt.
      answer = (_, _) => true;
      r.go('/y');
      await settle(tester);
      expect(asked, ['x', 'x']);
      expect(find.text('y'), findsOneWidget);
    });

    testWidgets('a prompt the user answers true lets the page go', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/x');
      final prompt = Completer<bool>();
      answer = (_, _) => prompt.future;
      r.go('/y');
      await settle(tester);
      prompt.complete(true);
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
    });

    testWidgets('the Ref stays valid across an await', (tester) async {
      final r = await boot(tester, initial: '/x');
      final provider = Provider<int>((ref) => 7);
      var read = 0;
      final context = tester.element(find.text('x'));
      final state = r.routerDelegate.state;
      final gate = Completer<void>();
      final done = leaveExit(context, state, 'x/leave.dart', (ref, page) async {
        await gate.future;
        read = ref.read(provider);
        return false;
      });
      expect(done, isA<Future<bool>>());
      gate.complete();
      expect(await (done as Future<bool>), isFalse);
      expect(read, 7);
    });

    testWidgets('a leave() that throws lets the page go and is reported', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/x');
      answer = (_, _) => throw StateError('boom');
      final seen = await reported(() async {
        r.go('/y');
        await settle(tester);
      });
      expect(find.text('y'), findsOneWidget);
      expect(seen, hasLength(1));
      expect(seen.single.exception, isA<StateError>());
      expect(seen.single.library, 'fespalier');
      expect(
        seen.single.context.toString(),
        contains('while running leave() of x/leave.dart'),
      );
    });

    testWidgets(
      'a leave() whose Future fails lets the page go and is reported',
      (tester) async {
        final r = await boot(tester, initial: '/x');
        answer = (_, _) async => throw StateError('later');
        final seen = await reported(() async {
          r.go('/y');
          await settle(tester);
        });
        expect(find.text('y'), findsOneWidget);
        expect(seen.map((d) => d.exception), [isA<StateError>()]);
        expect(
          seen.single.context.toString(),
          contains('while running leave() of x/leave.dart'),
        );
      },
    );

    test('leaveWithParams lets a page go whose segments do not parse', () {
      var ran = false;
      expect(
        leaveWithParams<int>(() => throw const BadSegment('id', 'abc', 'int'), (
          _,
        ) {
          ran = true;
          return false;
        }),
        isTrue,
      );
      expect(ran, isFalse);
      expect(leaveWithParams<int>(() => 3, (v) => v == 3), isTrue);
      expect(leaveWithParams<int>(() => 4, (v) => v == 3), isFalse);
    });
  });

  group('leaveWithoutAsking', () {
    testWidgets('lets the navigation through, and only that one', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/x');
      answer = (_, _) => false;
      leaveWithoutAsking(r, () => r.go('/y'));
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
      expect(asked, isEmpty);
      // The ticket is gone with the next navigation.
      r.go('/x');
      await settle(tester);
      r.go('/z');
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
    });

    testWidgets('a pop inside it is let through too', (tester) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      answer = (_, _) => false;
      leaveWithoutAsking(r, r.pop);
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
      expect(asked, isEmpty);
    });
  });

  group('a guard', () {
    testWidgets('a redirect after a refresh asks, sign-out included', (
      tester,
    ) async {
      var signedOut = false;
      final r = await boot(
        tester,
        initial: '/x',
        redirect: (uri) => signedOut && uri.path != '/z' ? '/z' : null,
      );
      answer = (_, _) => false;
      signedOut = true;
      r.refresh();
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
      // The one way round it is to say so.
      leaveWithoutAsking(r, r.refresh);
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('z'), findsOneWidget);
    });

    testWidgets('a redirect that the page allows goes', (tester) async {
      var signedOut = false;
      final r = await boot(
        tester,
        initial: '/x',
        redirect: (uri) => signedOut && uri.path != '/z' ? '/z' : null,
      );
      signedOut = true;
      r.refresh();
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('z'), findsOneWidget);
    });
  });

  group('the browser', () {
    testWidgets('a back that is refused reports the page URL again', (
      tester,
    ) async {
      // What the address bar was told, by location: the engine keeps it with each history entry
      // and hands it back on a back or forward.
      final told = <String, Object?>{};
      final reports = <Map<Object?, Object?>>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        (call) async {
          if (call.method == 'routeInformationUpdated') {
            final args = Map<Object?, Object?>.of(call.arguments as Map);
            reports.add(args);
            told['${args['uri'] ?? args['location']}'] = args['state'];
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
      final r = await boot(tester, initial: '/y');
      r.go('/x');
      await settle(tester);
      expect(told.keys, containsAll(['/y', '/x']));
      reports.clear();
      answer = (_, _) => false;
      await platformGo(tester, '/y', state: told['/y']);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
      expect(where(r), '/x');
      expect(
        reports,
        isNotEmpty,
        reason: 'the address bar is told where we are',
      );
      final last = reports.last;
      expect('${last['uri'] ?? last['location']}', '/x');
      expect(last['replace'], isFalse, reason: 'a new history entry');
    });

    testWidgets('a back that is allowed goes', (tester) async {
      final r = await boot(tester, initial: '/x');
      await platformGo(tester, '/y');
      expect(asked, ['x']);
      expect(find.text('y'), findsOneWidget);
      expect(where(r), '/y');
    });
  });

  group('the iOS back swipe', () {
    Future<void> swipe(WidgetTester tester) async {
      await tester.dragFrom(const Offset(2, 300), const Offset(600, 0));
      await settle(tester);
    }

    testWidgets('is off while the page has no source', (tester) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      await swipe(tester);
      expect(
        find.text('x'),
        findsOneWidget,
        reason: 'no source: leave() may ask something',
      );
      expect(asked, isEmpty);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

    testWidgets('is off while a source is dirty and on when it is clean', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      final source = sources['x'] = FakeSource('form', dirty: true);
      await push(tester, r, '/x');
      await swipe(tester);
      expect(find.text('x'), findsOneWidget);
      expect(asked, isEmpty);
      source.dirty = false;
      await tester.pump();
      await swipe(tester);
      expect(asked, [
        'x',
      ], reason: 'the swipe pops, and go_router asks leave()');
      expect(find.text('y'), findsOneWidget);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

    testWidgets('a page without a leave.dart swipes away as it always did', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/z');
      await swipe(tester);
      expect(find.text('y'), findsOneWidget);
      expect(asked, isEmpty);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
  });

  group('the scope', () {
    testWidgets('a page sees its sources, and a source that goes is not seen', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      final source = sources['x'] = FakeSource('form', dirty: true);
      await push(tester, r, '/x');
      final seen = <PageLeave>[];
      answer = (_, page) {
        seen.add(page);
        return false;
      };
      r.pop();
      await settle(tester);
      expect(seen.single.isDirty, isTrue);
      expect(seen.single.state.uri.path, '/x');
      source.dirty = false;
      r.pop();
      await settle(tester);
      expect(seen.last.isDirty, isFalse);
    });

    testWidgets('a page without sources is clean', (tester) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      final seen = <PageLeave>[];
      answer = (_, page) {
        seen.add(page);
        return true;
      };
      r.pop();
      await settle(tester);
      expect(seen.single.isDirty, isFalse);
      expect(seen.single.canKeep, isFalse);
    });

    testWidgets('keep and discard reach every source', (tester) async {
      final a = FakeSource('a', dirty: true, keeps: true);
      final b = FakeSource('b', dirty: true);
      final page = PageLeave(await anyState(tester), [a, b]);
      expect(page.isDirty, isTrue);
      expect(page.canKeep, isTrue);
      await page.keep();
      page.discard();
      expect(a.calls, ['keep', 'discard']);
      expect(b.calls, ['keep', 'discard']);
    });

    testWidgets('maybeOf is null outside a page with a leave.dart', (
      tester,
    ) async {
      await boot(tester, initial: '/y');
      expect(LeaveScope.maybeOf(tester.element(find.text('y'))), isNull);
    });

    testWidgets('/a/1 to /a/2 keeps the element: the sources follow the id', (
      tester,
    ) async {
      final r = await boot(tester);
      sources['a/1'] = FakeSource('form', dirty: true);
      r.go('/a/1');
      await settle(tester);
      answer = (_, _) => true;
      r.go('/a/2');
      await settle(tester);
      expect(asked, ['a/1 dirty']);
      expect(find.text('a/2'), findsOneWidget);
      asked.clear();
      r.go('/y');
      await settle(tester);
      expect(asked, ['a/2', 'a'], reason: 'the new instance has no source');
    });
  });

  group('remount and deferred pages', () {
    testWidgets(
      'a remounted page is asked when its segment changes, not its query',
      (tester) async {
        final r = await boot(tester, initial: '/rm/1');
        sources['rm'] = FakeSource('form', dirty: true);
        r.go('/rm/1?q=1');
        await settle(tester);
        expect(asked, isEmpty);
        r.go('/rm/2');
        await settle(tester);
        expect(asked, [
          'rm/1 dirty',
        ], reason: 'the rebuilt page registered its form again');
        expect(find.text('rm 2'), findsOneWidget);
      },
    );

    testWidgets('a remounted page keeps its sources for the next ask', (
      tester,
    ) async {
      sources['rm'] = FakeSource('form', dirty: true);
      final r = await boot(tester, initial: '/rm/1');
      sources['rm'] = FakeSource('form', dirty: true);
      r.go('/rm/1?q=1');
      await settle(tester);
      answer = (_, _) => false;
      r.go('/y');
      await settle(tester);
      expect(asked, [
        'rm/1 dirty',
      ], reason: 'the rebuilt page registered again');
      expect(find.text('rm 1'), findsOneWidget);
    });

    testWidgets('a deferred page is asked like any other', (tester) async {
      asked.clear();
      answer = (_, _) => false;
      final library = DeferredLibrary(deferred_page.loadLibrary, 'd/page.dart');
      await tester.runAsync(library.load);
      final r = GoRouter(
        initialLocation: '/d',
        routes: [
          GoRoute(
            path: '/d',
            onExit: (context, state) =>
                leaveExit(context, state, 'd/leave.dart', (ref, page) {
                  asked.add('d');
                  return answer('d', page);
                }),
            pageBuilder: (context, state) => MaterialPage<void>(
              key: state.pageKey,
              child: leaveScope(
                state,
                DeferredView(
                  library: library,
                  page: () => deferred_page.DeferredPage(),
                  loading: () => const Text('loading'),
                  error: (e, st, retry) => Text('error $e'),
                ),
              ),
            ),
          ),
          GoRoute(path: '/y', builder: (_, _) => const Text('y')),
        ],
      );
      await pumpRouter(tester, r);
      expect(find.text('deferred page'), findsOneWidget);
      r.go('/y');
      await settle(tester);
      expect(asked, ['d']);
      expect(find.text('deferred page'), findsOneWidget);
      answer = (_, _) => true;
      r.go('/y');
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
    });
  });

  group('review fixes', () {
    testWidgets(
      'a switch to a guarded tab is asked: its redirect may leave the shell',
      (tester) async {
        final r = await boot(tester);
        answer = (_, _) => false;
        guardOn = true;
        StatefulNavigationShell.of(tester.element(find.text('a'))).goBranch(2);
        await settle(tester);
        expect(asked, ['a']);
        expect(find.text('a'), findsOneWidget);
        r.go('/g');
        await settle(tester);
        expect(asked, ['a', 'a']);
        expect(where(r), '/a');
        // A tab without a guard of its own is still parked without asking.
        r.go('/b');
        await settle(tester);
        expect(asked, ['a', 'a']);
        expect(find.text('b'), findsOneWidget);
      },
    );

    testWidgets(
      'a double pop of a page awaiting its prompt completes it once',
      (tester) async {
        final r = await boot(tester, initial: '/y');
        await push(tester, r, '/x');
        final prompt = Completer<bool>();
        answer = (_, _) => prompt.future;
        r.pop();
        r.pop();
        await settle(tester);
        expect(asked, ['x']);
        prompt.complete(true);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('y'), findsOneWidget);
        expect(where(r), '/y');
      },
    );

    testWidgets('a back that joins the prompt of a go does not close the app', (
      tester,
    ) async {
      final closed = recordSystemNavigator(tester);
      final r = await boot(tester, initial: '/x');
      final prompt = Completer<bool>();
      answer = (_, _) => prompt.future;
      r.go('/y');
      await settle(tester);
      // The back stays pending while the prompt is open, so it is not awaited.
      unawaited(
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/navigation',
          const JSONMethodCodec().encodeMethodCall(
            const MethodCall('popRoute'),
          ),
          (_) {},
        ),
      );
      await settle(tester);
      expect(asked, ['x']);
      prompt.complete(true);
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
      expect(closed, isEmpty);
    });

    testWidgets(
      'leaveWithoutAsking with nothing to navigate covers no later pop',
      (tester) async {
        final r = await boot(tester, initial: '/y');
        await push(tester, r, '/x');
        answer = (_, _) => false;
        leaveWithoutAsking(r, () {});
        r.pop();
        await settle(tester);
        expect(asked, ['x']);
        expect(find.text('x'), findsOneWidget);
      },
    );

    testWidgets('a sign-out that fails leaves the pages asking', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/x');
      answer = (_, _) => false;
      final failed = leaveWithoutAsking(r, () async {
        throw StateError('offline');
      });
      await expectLater(Future<void>.value(failed), throwsStateError);
      r.pop();
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
    });

    testWidgets(
      'leaveWithoutAsking covers a pending Future, and then no more',
      (tester) async {
        final r = await boot(tester, initial: '/y');
        await push(tester, r, '/x');
        answer = (_, _) => false;
        final gate = Completer<void>();
        final pending = leaveWithoutAsking(r, () => gate.future);
        r.pop();
        await settle(tester);
        expect(asked, isEmpty);
        expect(find.text('y'), findsOneWidget);
        gate.complete();
        await pending;
        await push(tester, r, '/x');
        r.pop();
        await settle(tester);
        expect(asked, ['x']);
      },
    );

    testWidgets('a watch inside leave() does not run it again', (tester) async {
      final r = await boot(tester, initial: '/x');
      final bump = NotifierProvider<_Bump, int>(_Bump.new);
      final context = tester.element(find.text('x'));
      final state = r.routerDelegate.state;
      final container = ProviderScope.containerOf(context);
      final gate = Completer<bool>();
      var runs = 0;
      final done = leaveExit(context, state, 'x/leave.dart', (ref, page) {
        runs++;
        ref.watch(bump);
        return gate.future;
      });
      container.read(bump.notifier).value = 1;
      await tester.pump();
      gate.complete(false);
      expect(await (done as Future<bool>), isFalse);
      expect(runs, 1);
    });

    testWidgets(
      'replacing a pushed page with itself at another query is not asked',
      (tester) async {
        final r = await boot(tester, initial: '/y');
        await push(tester, r, '/x');
        answer = (_, _) => false;
        unawaited(r.replace<void>('/x?q=2'));
        await settle(tester);
        expect(asked, isEmpty);
        expect(find.text('x'), findsOneWidget);
        unawaited(r.replace<void>('/z'));
        await settle(tester);
        expect(asked, ['x']);
      },
    );

    testWidgets(
      'onBack handles the system back inside the page, or lets it pop',
      (tester) async {
        final r = await boot(tester, initial: '/y');
        var handled = 0;
        var consume = true;
        backs['x'] = () {
          handled++;
          return consume;
        };
        await push(tester, r, '/x');
        await systemBack(tester);
        expect(handled, 1);
        expect(asked, isEmpty);
        expect(find.text('x'), findsOneWidget);
        consume = false;
        await systemBack(tester);
        expect(handled, 2);
        expect(asked, ['x']);
        expect(find.text('y'), findsOneWidget);
      },
    );
  });

  group('a whole ShellRoute page on the root navigator', () {
    // go_router fixed `onExit` of a GoRoute inside a ShellRoute being skipped by a pop in 17.4.0
    // (CHANGELOG: "Fixes onExit ignored for GoRoute nested inside ShellRoute"); 17.0 to 17.3,
    // which is what Flutter below 3.38 resolves, pop the page without asking.
    testWidgets('a pop asks the leaf, refused and allowed', (tester) async {
      final r = await boot(tester, initial: '/y');
      await push(tester, r, '/s');
      expect(find.text('s'), findsOneWidget);
      answer = (_, _) => false;
      r.pop();
      await settle(tester);
      expect(asked, ['s']);
      expect(find.text('s'), findsOneWidget);
      answer = (_, _) => true;
      r.pop();
      await settle(tester);
      expect(find.text('y'), findsOneWidget);
    }, skip: onFlutterFloor);

    testWidgets('go away from it asks on every go_router', (tester) async {
      final r = await boot(tester, initial: '/s');
      answer = (_, _) => false;
      r.go('/y');
      await settle(tester);
      expect(asked, ['s']);
      expect(find.text('s'), findsOneWidget);
    });
  });
}

class _Bump extends Notifier<int> {
  @override
  int build() => 0;

  set value(int v) => state = v;
}
