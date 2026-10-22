// leave.dart (since 0.11.0): `leaveExit` is a GoRoute's `onExit`, `leaveScope` the wrapper of its
// page. What is asked, what is not, and what the back gestures do. The routers here are what
// the generator writes for a folder with a leave.dart, by hand.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';
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

/// How often the guard on the tab shell ran.
int shellRuns = 0;

/// A session the guards of `/inbox` and `/inbox2` watch.
final session = NotifierProvider<Session, bool>(Session.new);

class Session extends Notifier<bool> {
  @override
  bool build() => true;

  set signedIn(bool value) => state = value;
}

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

Widget page(String label, {bool appBar = false}) => Scaffold(
  appBar: appBar ? AppBar() : null,
  body: Center(child: Text(label)),
);

/// What the generator writes for a folder with a leave.dart: `onExit` and the page wrapper.
GoRoute leaving(
  String path,
  String label, {
  List<RouteBase> routes = const [],
  String Function(GoRouterState state)? labelOf,
  GoRouterRedirect? redirect,
  bool appBar = false,
}) {
  return GoRoute(
    path: path,
    redirect: redirect,
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
      var body = page(l, appBar: appBar);
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
        // A guard above the tabs, as the generator emits it: on the shell, not on each tab.
        redirect: (context, state) {
          shellRuns++;
          return null;
        },
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
      leaving(
        '/inbox',
        'inbox',
        redirect: (context, state) => refGuard(
          context,
          'g1@inbox',
          (ref) => ref.watch(session) ? null : '/login',
        ),
      ),
      leaving(
        '/inbox2',
        'inbox2',
        redirect: (context, state) =>
            refGuard(context, 'g2@inbox2', (ref) async {
              final signedIn = ref.watch(session);
              await Future<void>.value();
              return signedIn ? null : '/login';
            }),
      ),
      plain('/login', 'login'),
      // Redirect-only destinations that answer later than the guards fespalier counts.
      GoRoute(
        path: '/login2',
        redirect: (context, state) => refRedirect(context, (ref) async {
          for (var i = 0; i < 25; i++) {
            await Future<void>.value();
          }
          return '/login';
        }),
      ),
      GoRoute(
        path: '/login3',
        redirect: (context, state) => refRedirect(context, (ref) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return '/login';
        }),
      ),
      for (final (path, to) in [('/inbox3', '/login2'), ('/inbox4', '/login3')])
        leaving(
          path,
          path.substring(1),
          redirect: (context, state) => refGuard(
            context,
            'g@$path',
            (ref) => ref.watch(session) ? null : to,
          ),
        ),
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
  shellRuns = 0;
  answer = (_, _) => true;
  final r = router(initial: initial, redirect: redirect);
  await pumpRouter(tester, attached(r));
  return r;
}

String where(GoRouter r) =>
    r.routerDelegate.currentConfiguration.uri.toString();

/// The base page's location, then the location of each pushed page, bottom to top.
List<String> stackOf(GoRouter r) {
  final config = r.routerDelegate.currentConfiguration;
  final out = <ImperativeRouteMatch>[];
  pushedMatches(config.matches, out);
  return [
    config.matches.first.matchedLocation,
    for (final e in out) e.matches.uri.toString(),
  ];
}

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

/// Whether the guard of `/g` lets it through: a re-run after a change asks the guard again.
final class _GOpen extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

final _gOpen = NotifierProvider<_GOpen, bool>(_GOpen.new);

/// Whether the guard of `/q` lets it through: a guard of its own, that `_gOpen` has nothing to do with.
final _qOpen = NotifierProvider<_GOpen, bool>(_GOpen.new);

/// Whether the guard of `/gw` lets it through: a guard of its own, so that a test can turn it to
/// refuse without the guards of `/g` and `/oa` (which watch `_gOpen`) noticing.
final _wOpen = NotifierProvider<_GOpen, bool>(_GOpen.new);

void main() {
  // The tests of a pushed page's guard run in every order of what listens to the router before the
  // Router widget does (test/support/attach_order.dart): a generated app has DevTools' or
  // telemetry's listener in front, and a router built by hand has none.
  inEveryOrder(pushedPageGroups);
  otherGroups();
}

/// The re-run of a guarded pushed page, and a guarded base under one.
void pushedPageGroups() {
  // A guard's re-run of a pushed page (since 0.21.0) asks `leave()` as a base page's redirect does:
  // nothing when the guard passes again (the page is replaced by itself), the question when it
  // moves the page. The base page's side is in 'signing out through fespalier guards' below.
  group('a re-run of a guarded pushed page (fespalier/fespalier#258)', () {
    var gRuns = 0;

    /// How often the guard of `/q` ran: a guard of its own, that no change of `_gOpen` concerns.
    var qRuns = 0;

    /// When set, the guard of `/g4` answers once it completes: a guard that takes a while.
    Completer<void>? gGate;

    /// How many times the guard of `/oa`, a base page's, awaits before it answers.
    var baseAwaits = 0;

    /// How often the guard of `/g5` was evaluated: from the third on, it waits for [gGate].
    var g5Evals = 0;

    /// How often the guard of `/f` ran, how often its page was built, and whether it throws.
    var fRuns = 0;
    var fBuilt = 0;
    var fFails = false;

    /// `/g` has a sync guard and `/g2` an async one, both on `_gOpen`, both with a `leave.dart`. The
    /// tabs hold a guarded page of their own, pushed inside the shell.
    GoRouter guarded() => GoRouter(
      initialLocation: '/y',
      navigatorKey: rootKey,
      routes: [
        GoRoute(path: '/y', builder: (_, _) => const Text('y')),
        leaving('/x', 'x'),
        leaving(
          '/g',
          'g',
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'g1@g', (ref) {
              gRuns++;
              return ref.watch(_gOpen) ? null : '/y';
            }),
          ),
        ),
        leaving(
          '/g2',
          'g2',
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'g2@g2', (ref) async {
              gRuns++;
              final open = ref.watch(_gOpen);
              await Future<void>.value();
              return open ? null : '/y';
            }),
          ),
        ),
        leaving(
          '/q',
          'q',
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'q1@q', (ref) {
              qRuns++;
              return ref.watch(_qOpen) ? null : '/y';
            }),
          ),
        ),
        // The page with an app bar, so the back button of its bar is there to press.
        leaving(
          '/g4',
          'g4',
          appBar: true,
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'g4@g4', (ref) {
              gRuns++;
              final answer = ref.watch(_gOpen) ? null : '/y';
              final wait = gGate;
              return wait == null
                  ? Future<String?>.value(answer)
                  : wait.future.then<String?>((_) => answer);
            }),
          ),
        ),
        // The same page with a guard on a flag of its own (`_wOpen`).
        leaving(
          '/gw',
          'gw',
          appBar: true,
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'gw@gw', (ref) {
              final answer = ref.watch(_wOpen) ? null : '/y';
              final wait = gGate;
              return wait == null
                  ? Future<String?>.value(answer)
                  : wait.future.then<String?>((_) => answer);
            }),
          ),
        ),
        // A guard on `_gOpen` whose third evaluation waits for `gGate`: the push, the change that
        // `/g` notices too, and the re-run that change asks for.
        leaving(
          '/g5',
          'g5',
          appBar: true,
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'g5@g5', (ref) {
              final answer = ref.watch(_gOpen) ? null : '/y';
              return ++g5Evals >= 3
                  ? gGate!.future.then<String?>((_) => answer)
                  : Future<String?>.value(answer);
            }),
          ),
        ),
        // A guard that throws on demand, and the generated page builder of a guarded route.
        GoRoute(
          path: '/f',
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'f1@f', (ref) {
              fRuns++;
              if (fFails) throw StateError('f fails');
              return null;
            }),
          ),
          pageBuilder: (context, state) => MaterialPage<void>(
            key: state.pageKey,
            child:
                refusedView(context, state) ??
                Builder(
                  builder: (_) {
                    fBuilt++;
                    return const Text('F PAGE');
                  },
                ),
          ),
        ),
        // A base page with an asynchronous guard of its own, that awaits `baseAwaits` times.
        leaving(
          '/oa',
          'oa',
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(context, 'ga@oa', (ref) async {
              final open = ref.watch(_gOpen);
              for (var i = 0; i < baseAwaits; i++) {
                await Future<void>.value();
              }
              return open ? null : '/y';
            }),
          ),
        ),
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => shell,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/tab',
                  builder: (_, _) => const Text('tab'),
                  routes: [
                    leaving(
                      'g',
                      'tab/g',
                      redirect: (context, state) => runRedirect(
                        state,
                        () => refGuard(context, 'g3@tab', (ref) {
                          gRuns++;
                          return ref.watch(_gOpen) ? null : '/y';
                        }),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/tab2', builder: (_, _) => const Text('tab2')),
              ],
            ),
          ],
        ),
      ],
    );

    Future<ProviderContainer> start(WidgetTester tester, GoRouter r) async {
      asked.clear();
      sources.clear();
      gRuns = 0;
      qRuns = 0;
      gGate = null;
      baseAwaits = 0;
      g5Evals = 0;
      fRuns = 0;
      fBuilt = 0;
      fFails = false;
      answer = (_, _) => false;
      return pumpRouter(tester, attached(r));
    }

    for (final label in ['g', 'g2', 'tab/g']) {
      final location = label == 'tab/g' ? '/tab/g' : '/$label';

      testWidgets('/$label: a re-run that passes again asks nothing, with a '
          'leave() that refuses', (tester) async {
        final r = guarded();
        await start(tester, r);
        // Only /x lets go; the guarded page refuses every question.
        answer = (l, _) => l == 'x';
        sources[label] = FakeSource(label, dirty: true);
        if (label == 'tab/g') r.go('/tab');
        await settle(tester);
        await push(tester, r, location);
        expect(gRuns, 1);
        await push(tester, r, '/x');
        r.pop();
        await settle(tester);
        // The page is on top again, and go_router showed it without its redirect: its guard ran
        // again and passed, and replacing the page with itself asked nothing of it.
        expect(gRuns, 2);
        expect(asked, ['x']);
        expect(currentLocation(tester), location);
        expect(find.text(label), findsOneWidget);
      });

      testWidgets('/$label: a re-run that moves the page asks, and a leave() '
          'that refuses keeps it', (tester) async {
        final r = guarded();
        final c = await start(tester, r);
        sources[label] = FakeSource(label, dirty: true);
        if (label == 'tab/g') r.go('/tab');
        await settle(tester);
        await push(tester, r, location);
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(asked, ['$label dirty']);
        expect(currentLocation(tester), location);
        expect(find.text(label), findsOneWidget);
      });

      testWidgets('/$label: a re-run that moves the page asks, and a leave() '
          'that allows lets it go', (tester) async {
        final r = guarded();
        final c = await start(tester, r);
        answer = (_, _) => true;
        sources[label] = FakeSource(label, dirty: true);
        if (label == 'tab/g') r.go('/tab');
        await settle(tester);
        await push(tester, r, location);
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(asked, ['$label dirty']);
        expect(currentLocation(tester), '/y');
        expect(find.text(label), findsNothing);
      });

      testWidgets('/$label: leaveWithoutAsking lets the re-run that moves the '
          'page through', (tester) async {
        final r = guarded();
        final c = await start(tester, r);
        sources[label] = FakeSource(label, dirty: true);
        if (label == 'tab/g') r.go('/tab');
        await settle(tester);
        await push(tester, r, location);
        final done = leaveWithoutAsking(
          r,
          () => c.read(_gOpen.notifier).set(false),
        );
        await settle(tester);
        await done;
        expect(asked, isEmpty);
        expect(currentLocation(tester), '/y');
      });
    }
    // A re-run that moves the page and is refused by its leave() leaves the page where it was, and its
    // guard with it: the guard stays that page's.
    group('after a re-run that a leave() refused', () {
      for (final label in ['g', 'g2']) {
        /// `/label` is pushed, dirty, and its guard now refuses: the question is asked and refused.
        Future<ProviderContainer> refused(
          WidgetTester tester,
          GoRouter r,
        ) async {
          final c = await start(tester, r);
          sources[label] = FakeSource(label, dirty: true);
          await push(tester, r, '/$label');
          c.read(_gOpen.notifier).set(false);
          await settle(tester);
          expect(asked, ['$label dirty']);
          expect(currentLocation(tester), '/$label');
          return c;
        }

        testWidgets('/$label: a change that makes the guard pass asks nothing '
            'and keeps the page', (tester) async {
          final r = guarded();
          final c = await refused(tester, r);
          c.read(_gOpen.notifier).set(true);
          await settle(tester);
          expect(asked, ['$label dirty']);
          expect(currentLocation(tester), '/$label');
          expect(find.text(label), findsOneWidget);
        });

        testWidgets('/$label: a change that refuses it again is a move of its '
            'own, and is asked', (tester) async {
          final r = guarded();
          final c = await refused(tester, r);
          c.read(_gOpen.notifier).set(true);
          await settle(tester);
          answer = (_, _) => true;
          c.read(_gOpen.notifier).set(false);
          await settle(tester);
          expect(asked, ['$label dirty', '$label dirty']);
          expect(currentLocation(tester), '/y');
        });

        testWidgets('/$label: nothing it watched is bound to a page pushed '
            'later', (tester) async {
          final r = guarded();
          final c = await refused(tester, r);
          answer = (l, _) => l == 'q';
          await push(tester, r, '/q');
          expect(qRuns, 1);
          // The guard of `/$label` changes while the unrelated page is on top: that page has nothing
          // to do with it, and its own guard does not run again.
          c.read(_gOpen.notifier).set(true);
          await settle(tester);
          expect(qRuns, 1);
          expect(currentLocation(tester), '/q');
          expect(asked, ['$label dirty']);
        });

        testWidgets('/$label: a pop back to it while its guard still refuses '
            'asks again', (tester) async {
          final r = guarded();
          await refused(tester, r);
          answer = (l, _) => l == 'x';
          await push(tester, r, '/x');
          r.pop();
          await settle(tester);
          expect(asked, ['$label dirty', 'x', '$label dirty']);
          expect(currentLocation(tester), '/$label');
        });
      }
    });

    // A way back while the re-run is on the way (the guard is still asking): the person's pop is
    // asked as it is with no re-run, and the page does not come back once it has gone.
    group('a pop while the re-run waits', () {
      /// `/g4` (a guard that waits for [gGate]) pushed, `/x` pushed over it and popped, so go_router
      /// shows `/g4` again and its guard is running again. The page is dirty.
      Future<GoRouter> waiting(
        WidgetTester tester, {
        required bool isAsync,
      }) async {
        final r = guarded();
        await start(tester, r);
        answer = (l, _) => l == 'x';
        sources['g4'] = FakeSource('g4', dirty: true);
        await push(tester, r, '/g4');
        await push(tester, r, '/x');
        if (isAsync) gGate = Completer<void>();
        r.pop();
        await settle(tester);
        expect(find.text('g4'), findsOneWidget);
        expect(asked, ['x']);
        asked.clear();
        return r;
      }

      for (final isAsync in [false, true]) {
        final kind = isAsync ? 'async' : 'sync';

        testWidgets('GoRouter.pop asks a dirty page, and a refusal keeps it '
            '($kind guard)', (tester) async {
          final r = await waiting(tester, isAsync: isAsync);
          r.pop();
          await settle(tester);
          expect(asked, ['g4 dirty']);
          expect(currentLocation(tester), '/g4');
          gGate?.complete();
          await settle(tester);
          expect(asked, ['g4 dirty']);
          expect(currentLocation(tester), '/g4');
          expect(find.text('g4'), findsOneWidget);
        });

        testWidgets(
          'GoRouter.pop asks a dirty page, and an answer that lets it '
          'go leaves it for good ($kind guard)',
          (tester) async {
            final r = await waiting(tester, isAsync: isAsync);
            answer = (_, _) => true;
            r.pop();
            await settle(tester);
            expect(asked, ['g4 dirty']);
            expect(currentLocation(tester), '/y');
            gGate?.complete();
            await settle(tester);
            expect(asked, ['g4 dirty'], reason: 'asked once, not again');
            expect(currentLocation(tester), '/y');
            expect(find.text('g4'), findsNothing);
          },
        );

        testWidgets('the back of the page (Navigator.maybePop) asks a dirty '
            'page, and a refusal keeps it ($kind guard)', (tester) async {
          await waiting(tester, isAsync: isAsync);
          final navigator = Navigator.of(tester.element(find.text('g4')));
          await navigator.maybePop();
          await settle(tester);
          expect(asked, ['g4 dirty']);
          expect(currentLocation(tester), '/g4');
          gGate?.complete();
          await settle(tester);
          expect(asked, ['g4 dirty']);
          expect(currentLocation(tester), '/g4');
        });

        testWidgets('the system back asks a dirty page ($kind guard)', (
          tester,
        ) async {
          await waiting(tester, isAsync: isAsync);
          await systemBack(tester);
          expect(asked, ['g4 dirty']);
          expect(currentLocation(tester), '/g4');
          gGate?.complete();
          await settle(tester);
          expect(asked, ['g4 dirty']);
          expect(currentLocation(tester), '/g4');
        });
      }

      testWidgets('a pop that was refused is asked again, while the guard waits '
          'and after it answered', (tester) async {
        final r = await waiting(tester, isAsync: true);
        final navigator = Navigator.of(tester.element(find.text('g4')));
        await navigator.maybePop();
        await settle(tester);
        await navigator.maybePop();
        await settle(tester);
        expect(asked, ['g4 dirty', 'g4 dirty']);
        expect(currentLocation(tester), '/g4');
        // The guard answers and passes: the carried re-run lands, asks nothing and leaves the page where it is.
        gGate!.complete();
        await settle(tester);
        expect(asked, ['g4 dirty', 'g4 dirty']);
        expect(currentLocation(tester), '/g4');
        expect(find.text('g4'), findsOneWidget);
        // The question that follows is the person's like the first ones: asked, and it lets the page go.
        answer = (_, _) => true;
        r.pop();
        await settle(tester);
        expect(asked, ['g4 dirty', 'g4 dirty', 'g4 dirty']);
        expect(currentLocation(tester), '/y');
      });

      testWidgets('a guard that never answers does not keep the re-run of '
          'another page from asking', (tester) async {
        final r = await waiting(tester, isAsync: true);
        // `/g4` is left with its guard still waiting for ever.
        answer = (_, _) => true;
        await Navigator.of(tester.element(find.text('g4'))).maybePop();
        await settle(tester);
        expect(currentLocation(tester), '/y');
        asked.clear();
        // Another page, dirty, whose guard now refuses when the page is uncovered: it moves, and asks.
        answer = (l, _) => l == 'x';
        sources['g'] = FakeSource('g', dirty: true);
        await push(tester, r, '/g');
        await push(tester, r, '/x');
        ProviderScope.containerOf(
          tester.element(find.text('x')),
        ).read(_gOpen.notifier).set(false);
        r.pop();
        await settle(tester);
        expect(asked, ['x', 'g dirty']);
        expect(currentLocation(tester), '/g');
      });

      testWidgets('a pop that is allowed after the guard answered leaves the '
          'page for good', (tester) async {
        final r = await waiting(tester, isAsync: true);
        final prompt = Completer<bool>();
        answer = (_, _) => prompt.future;
        r.pop();
        await settle(tester);
        expect(asked, ['g4 dirty']);
        // The guard answers while the question is open: it passes, and the page is replaced by itself.
        gGate!.complete();
        await settle(tester);
        expect(find.text('g4'), findsOneWidget);
        prompt.complete(true);
        await settle(tester);
        expect(currentLocation(tester), '/y');
        expect(find.text('g4'), findsNothing);
        expect(asked, ['g4 dirty'], reason: 'asked once');
      });

      testWidgets('a pop that is allowed while the guard waits leaves the page '
          'for good, asked once', (tester) async {
        await waiting(tester, isAsync: true);
        answer = (_, _) => true;
        final navigator = Navigator.of(tester.element(find.text('g4')));
        await navigator.maybePop();
        await settle(tester);
        expect(asked, ['g4 dirty']);
        expect(currentLocation(tester), '/y');
        gGate!.complete();
        await settle(tester);
        expect(asked, ['g4 dirty']);
        expect(currentLocation(tester), '/y');
        expect(find.text('g4'), findsNothing);
      });
    });

    // The base page's guard is asynchronous too, and the person leaves the page while the re-run of
    // its guard waits. The pop is the person's and nothing restores the stack for it: the page goes,
    // and it is asked once. The router is told to drop the re-run only after the pop, so a base that
    // is still asking cannot put the page back.
    group('a pop while the re-run waits, over a base whose guard awaits', () {
      for (final awaits in [1, 2, 4]) {
        for (final how in [
          'the back button of the app bar',
          'the system back',
          'GoRouter.pop',
          'context.pop',
        ]) {
          testWidgets('$how, $awaits await${awaits == 1 ? '' : 's'}: the page '
              'goes, asked once, and does not come back', (tester) async {
            final r = guarded();
            await start(tester, r);
            baseAwaits = awaits;
            answer = (l, _) => l == 'x';
            sources['g4'] = FakeSource('g4', dirty: true);
            r.go('/oa');
            await settle(tester);
            await push(tester, r, '/g4');
            await push(tester, r, '/x');
            gGate = Completer<void>();
            r.pop();
            await settle(tester);
            expect(find.text('g4'), findsOneWidget);
            expect(asked, ['x']);
            asked.clear();
            answer = (_, _) => true;
            switch (how) {
              case 'the back button of the app bar':
                await tester.pageBack();
              case 'the system back':
                await systemBack(tester);
              case 'GoRouter.pop':
                r.pop();
              default:
                tester.element(find.text('g4')).pop();
            }
            await settle(tester);
            expect(asked, ['g4 dirty']);
            expect(currentLocation(tester), '/oa');
            expect(find.text('g4'), findsNothing);
            expect(find.text('oa'), findsOneWidget);
            // The guard of the page answers late: the re-run does not land and bring it back.
            gGate!.complete();
            await settle(tester);
            expect(asked, ['g4 dirty'], reason: 'asked once, not again');
            expect(currentLocation(tester), '/oa');
            expect(find.text('g4'), findsNothing);
          });
        }
      }
    });

    // The same way back, refused by the page's `leave()` or left open while the guard waits, and
    // allowed afterwards: the question is the person's, the base page may still be asking, and
    // nothing the re-run does changes the page while a question about it is open or was refused.
    group('a question about the page while the re-run waits, over a base whose '
        'guard awaits', () {
      for (final awaits in [1, 2, 4]) {
        for (final how in [
          'the back button of the app bar',
          'the system back',
          'GoRouter.pop',
          'context.pop',
        ]) {
          /// `/gw` (dirty) over `/oa`, `/x` over it and popped: the re-run of the guard of `/gw` waits.
          Future<GoRouter> waiting(WidgetTester tester) async {
            final r = guarded();
            await start(tester, r);
            baseAwaits = awaits;
            answer = (l, _) => l == 'x';
            sources['gw'] = FakeSource('gw', dirty: true);
            r.go('/oa');
            await settle(tester);
            await push(tester, r, '/gw');
            await push(tester, r, '/x');
            gGate = Completer<void>();
            r.pop();
            await settle(tester);
            expect(find.text('gw'), findsOneWidget);
            asked.clear();
            return r;
          }

          Future<void> back(WidgetTester tester, GoRouter r) async {
            switch (how) {
              case 'the back button of the app bar':
                await tester.pageBack();
              case 'the system back':
                await systemBack(tester);
              case 'GoRouter.pop':
                r.pop();
              default:
                tester.element(find.text('gw')).pop();
            }
            await settle(tester);
          }

          final label = '$how, $awaits await${awaits == 1 ? '' : 's'}';

          testWidgets('$label: a refusal keeps the page, and the next back '
              'goes', (tester) async {
            final r = await waiting(tester);
            answer = (_, _) => false;
            await back(tester, r);
            expect(asked, ['gw dirty']);
            expect(stackOf(r), ['/oa', '/gw']);
            gGate!.complete();
            await settle(tester);
            expect(asked, ['gw dirty']);
            expect(stackOf(r), ['/oa', '/gw']);
            expect(find.text('gw'), findsOneWidget);
            answer = (_, _) => true;
            await back(tester, r);
            expect(asked, ['gw dirty', 'gw dirty']);
            expect(stackOf(r), ['/oa']);
            await settle(tester);
            expect(stackOf(r), ['/oa']);
            expect(find.text('gw'), findsNothing);
          });

          testWidgets('$label: a yes that comes after the guard answered '
              'lets the page go', (tester) async {
            final r = await waiting(tester);
            final prompt = Completer<bool>();
            answer = (_, _) => prompt.future;
            await back(tester, r);
            expect(asked, ['gw dirty']);
            gGate!.complete();
            await settle(tester);
            expect(stackOf(r), ['/oa', '/gw']);
            prompt.complete(true);
            await settle(tester);
            expect(asked, ['gw dirty']);
            expect(stackOf(r), ['/oa']);
            expect(find.text('gw'), findsNothing);
          });

          testWidgets('$label: a yes that comes before the guard answered '
              'lets the page go', (tester) async {
            final r = await waiting(tester);
            final prompt = Completer<bool>();
            answer = (_, _) => prompt.future;
            await back(tester, r);
            prompt.complete(true);
            await settle(tester);
            expect(stackOf(r), ['/oa']);
            gGate!.complete();
            await settle(tester);
            expect(asked, ['gw dirty']);
            expect(stackOf(r), ['/oa']);
            expect(find.text('gw'), findsNothing);
          });
        }
      }
    });

    // A pushed guarded page that is uncovered runs its guard again, however it was uncovered, and a
    // page that is held back is never built before its guard has passed. A page that goes while the
    // re-run of the page above it still waits must not make the commit look like a push: the router's
    // route information is still that re-run's `replace`, and a commit taken for a push marks the
    // page it uncovers as one whose guard passed, and runs nothing for it.
    group('a pop while the re-run of the page above it waits', () {
      /// `/g` (a guard on `_gOpen`) is pushed, `/gw` over it, `/x` over that, and `/x` is popped: the
      /// re-run of `/gw` waits for [gGate]. While `/g` is covered its guard turns to refuse.
      Future<(GoRouter, ProviderContainer)> covered(WidgetTester tester) async {
        final r = guarded();
        final c = await start(tester, r);
        answer = (_, _) => true;
        await push(tester, r, '/g');
        await push(tester, r, '/gw');
        await push(tester, r, '/x');
        gGate = Completer<void>();
        r.pop();
        await settle(tester);
        expect(stackOf(r), ['/y', '/g', '/gw']);
        expect(find.text('gw'), findsOneWidget);
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(stackOf(r), [
          '/y',
          '/g',
          '/gw',
        ], reason: '/g is covered: it waits');
        return (r, c);
      }

      for (final how in [
        'the back button of the app bar',
        'the system back',
        'GoRouter.pop',
        'context.pop',
      ]) {
        testWidgets('$how: the page it uncovers runs its guard again', (
          tester,
        ) async {
          final (r, _) = await covered(tester);
          final runs = gRuns;
          switch (how) {
            case 'the back button of the app bar':
              await tester.pageBack();
            case 'the system back':
              await systemBack(tester);
            case 'GoRouter.pop':
              r.pop();
            default:
              tester.element(find.text('gw')).pop();
          }
          await settle(tester);
          await settle(tester);
          expect(gRuns, greaterThan(runs), reason: "/g's guard ran again");
          expect(find.text('g'), findsNothing, reason: "/g's guard refuses");
          expect(stackOf(r).last, '/y');
          // The guard of the page that went answers late: nothing comes back.
          gGate!.complete();
          await settle(tester);
          expect(find.text('g'), findsNothing);
          expect(find.text('gw'), findsNothing);
          expect(stackOf(r).last, '/y');
        });
      }

      testWidgets('one change that two pushed pages check, and the back button '
          'during the re-run of the top one', (tester) async {
        final r = guarded();
        final c = await start(tester, r);
        answer = (_, _) => true;
        gGate = Completer<void>();
        await push(tester, r, '/g');
        await push(tester, r, '/g5');
        expect(stackOf(r), ['/y', '/g', '/g5']);
        // The role is revoked: /g5 notices on top, /g while it is covered.
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(g5Evals, 3, reason: "the re-run of /g5's guard waits");
        expect(stackOf(r), ['/y', '/g', '/g5']);
        final runs = gRuns;
        await tester.pageBack();
        await settle(tester);
        await settle(tester);
        expect(gRuns, greaterThan(runs), reason: "/g's guard ran again");
        expect(find.text('g'), findsNothing);
        expect(stackOf(r).last, '/y');
      });

      testWidgets('a held page is not built when the page above it goes', (
        tester,
      ) async {
        final r = guarded();
        await start(tester, r);
        answer = (_, _) => true;
        // The push of /f failed: go_router shows the entry as the page after a refresh, and the page
        // is held back until its guard has passed.
        fFails = true;
        await push(tester, r, '/f');
        expect(find.text('F PAGE'), findsNothing);
        await push(tester, r, '/gw');
        gGate = Completer<void>();
        r.refresh();
        await settle(tester);
        expect(stackOf(r), ['/y', '/f', '/gw']);
        expect(fBuilt, 0);
        final runs = fRuns;
        await tester.pageBack();
        await settle(tester);
        await settle(tester);
        expect(fBuilt, 0, reason: 'its guard has not passed: never built');
        expect(find.text('F PAGE'), findsNothing);
        expect(fRuns, greaterThan(runs), reason: "/f's guard ran again");
        gGate!.complete();
        await settle(tester);
        expect(fBuilt, 0);
        expect(find.text('F PAGE'), findsNothing);
      });
    });

    // A re-run lands with all its answers (an asynchronous one is carried on by a re-run that replays
    // them), and a landing that moves the page asks `leave()` as any move does, also when the person
    // refused a question about the page while the guard waited: that was a question about the pop.
    // A refusal at the landing keeps the page and its guard. A landing that passes asks nothing, and
    // is refused only while a question about the page is open, so its answer finds the entry.
    group('a re-run that lands after a refused question', () {
      /// `/gw` is pushed (dirty), `/x` over it and popped: its guard waits for [gGate]. The person's
      /// back is asked and refused meanwhile. [base] is the page under them. Turns the guard to refuse
      /// while the page is covered when [closed] is true.
      Future<(GoRouter, ProviderContainer)> refusedBack(
        WidgetTester tester, {
        String base = '/y',
        bool closed = false,
        void Function(Future<String?> push)? onPush,
      }) async {
        final r = guarded();
        final c = await start(tester, r);
        baseAwaits = 2;
        answer = (l, _) => l == 'x';
        sources['gw'] = FakeSource('gw', dirty: true);
        if (base != '/y') {
          r.go(base);
          await settle(tester);
        }
        final pushed = r.push<String>('/gw');
        onPush?.call(pushed);
        await settle(tester);
        await push(tester, r, '/x');
        if (closed) c.read(_wOpen.notifier).set(false);
        await settle(tester);
        gGate = Completer<void>();
        r.pop();
        await settle(tester);
        expect(find.text('gw'), findsOneWidget);
        asked.clear();
        answer = (_, _) => false;
        await Navigator.of(tester.element(find.text('gw'))).maybePop();
        await settle(tester);
        expect(asked, ['gw dirty']);
        return (r, c);
      }

      for (final base in ['/y', '/oa']) {
        testWidgets('over $base: a guard that now moves the page moves it '
            'once the person has made it clean', (tester) async {
          final (r, _) = await refusedBack(tester, base: base, closed: true);
          // The person cleans the page, and the guard answers: it refuses.
          sources['gw']!.dirty = false;
          answer = (_, _) => true;
          gGate!.complete();
          await settle(tester);
          await settle(tester);
          expect(find.text('gw'), findsNothing, reason: 'its guard refuses');
          expect(stackOf(r), [base, '/y']);
          // Asked once more, as the move it is, and not about a dirty page.
          expect(asked, ['gw dirty', 'gw']);
        });

        testWidgets('over $base: a guard that now moves the page asks again '
            'when the page is still dirty, and a refusal keeps it', (
          tester,
        ) async {
          final (r, _) = await refusedBack(tester, base: base, closed: true);
          gGate!.complete();
          await settle(tester);
          await settle(tester);
          expect(asked, ['gw dirty', 'gw dirty']);
          expect(stackOf(r), [base, '/gw']);
          expect(find.text('gw'), findsOneWidget);
          // Nothing asks again by itself: the person refused the move.
          for (var i = 0; i < 20; i++) {
            await tester.pump();
          }
          expect(asked, ['gw dirty', 'gw dirty']);
          expect(stackOf(r), [base, '/gw']);
          // And the page is not stuck: the question that follows is the person's, asked as usual.
          answer = (_, _) => true;
          r.pop();
          await settle(tester);
          expect(asked, ['gw dirty', 'gw dirty', 'gw dirty']);
          expect(stackOf(r), [base]);
        });

        testWidgets('over $base: a guard that passes asks nothing more, and '
            'keeps the page', (tester) async {
          final (r, _) = await refusedBack(tester, base: base);
          gGate!.complete();
          await settle(tester);
          await settle(tester);
          expect(asked, ['gw dirty']);
          expect(stackOf(r), [base, '/gw']);
          for (var i = 0; i < 20; i++) {
            await tester.pump();
          }
          expect(asked, ['gw dirty']);
        });
      }

      // The landing asks the move, and a refusal keeps the page. A press of the person's right after
      // it, before a frame has run, is a question about the page like any other and is asked as
      // usual: a yes pops the page to where a pop goes.
      for (final base in ['/y', '/oa']) {
        testWidgets('over $base: a press right after the landing that a refusal '
            'kept is asked, and a yes pops the page', (tester) async {
          final (r, _) = await refusedBack(tester, base: base, closed: true);
          gGate!.complete();
          // The guard answers and the landing asks the move, in microtasks: no frame has run. The
          // person refuses it again.
          await tester.idle();
          expect(asked, ['gw dirty', 'gw dirty'], reason: 'the landing asked');
          expect(stackOf(r), [base, '/gw']);
          answer = (_, _) => true;
          await Navigator.of(tester.element(find.text('gw'))).maybePop();
          await settle(tester);
          await settle(tester);
          expect(asked, ['gw dirty', 'gw dirty', 'gw dirty']);
          // The page went to where a pop goes, not where its guard wanted to send it.
          expect(stackOf(r), [base]);
          expect(find.text('gw'), findsNothing);
        });

        // The guard that wanted to move the page passes again, a few frames after the landing that the
        // person refused: the page is not moved, and the base's refresh asks it once when the base is
        // under a guard of its own. Never more.
        for (final frames in [0, 1, 2]) {
          testWidgets('over $base: the guard passes again $frames frames '
              'after the refused move: the page is asked at most once more', (
            tester,
          ) async {
            final (r, c) = await refusedBack(tester, base: base, closed: true);
            gGate!.complete();
            await tester.idle();
            for (var i = 0; i < frames; i++) {
              await tester.pump();
            }
            final before = asked.length;
            answer = (_, _) => true;
            c.read(_wOpen.notifier).set(true);
            await settle(tester);
            await settle(tester);
            expect(
              asked.length - before,
              lessThanOrEqualTo(base == '/oa' ? 1 : 0),
            );
            expect(stackOf(r), [base, '/gw']);
            expect(find.text('gw'), findsOneWidget);
            final after = asked.length;
            for (var i = 0; i < 20; i++) {
              await tester.pump();
            }
            expect(asked.length, after, reason: 'nothing asks again by itself');
          });
        }
      }

      // The guard's move is asked at its landing, with no frame: fespalier schedules none and waits
      // for none, so an app in the background is asked as soon as the guard answers.
      // UNCHECKED on a device: that the question shows while the app is hidden.
      testWidgets('with the app in the background no frame comes, and the '
          "guard's move is asked at once", (tester) async {
        final (r, _) = await refusedBack(tester, closed: true);
        final binding = tester.binding;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        gGate!.complete();
        await tester.idle();
        expect(
          binding.hasScheduledFrame,
          isFalse,
          reason: 'nobody asked for one',
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump();
        }
        expect(asked, [
          'gw dirty',
          'gw dirty',
        ], reason: 'asked as the move it is, with no frame');
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await settle(tester);
        expect(asked, ['gw dirty', 'gw dirty'], reason: 'and not again');
        expect(stackOf(r), ['/y', '/gw']);
      });

      for (final yes in [true, false]) {
        testWidgets('a question still open when the guard that moves the page '
            'answers: ${yes ? 'a yes' : 'a no'} settles both', (tester) async {
          final (r, _) = await refusedBack(tester, closed: true);
          // The person's back is asked again and left open.
          final prompt = Completer<bool>();
          answer = (_, _) => prompt.future;
          await Navigator.of(tester.element(find.text('gw'))).maybePop();
          await settle(tester);
          expect(asked, ['gw dirty', 'gw dirty']);
          gGate!.complete();
          await settle(tester);
          await settle(tester);
          // The landing waits for the same question: nobody is asked a third time.
          expect(asked, ['gw dirty', 'gw dirty']);
          expect(stackOf(r), ['/y', '/gw']);
          prompt.complete(yes);
          await settle(tester);
          await settle(tester);
          expect(asked, ['gw dirty', 'gw dirty']);
          expect(stackOf(r), yes ? ['/y'] : ['/y', '/gw']);
          expect(find.text('gw'), yes ? findsNothing : findsOneWidget);
        });
      }

      for (final refused in [true, false]) {
        testWidgets('${refused ? 'after a refused question, ' : ''}the app\'s own '
            'replace of the page gets the result it pops with', (tester) async {
          final pushedDone = <String?>[];
          final replacedDone = <String?>[];
          late final GoRouter r;
          late final ProviderContainer c;
          if (refused) {
            (r, c) = await refusedBack(
              tester,
              onPush: (f) => unawaited(f.then(pushedDone.add)),
            );
            gGate!.complete();
            await settle(tester);
            expect(asked, ['gw dirty'], reason: 'the landing passed: unasked');
          } else {
            r = guarded();
            c = await start(tester, r);
            unawaited(r.push<String>('/gw').then(pushedDone.add));
            await settle(tester);
          }
          // The app replaces the page itself, a re-run of its guard follows (its guard turns to refuse,
          // and the move lets the page go), and the page that stands in for it pops with a result.
          unawaited(r.replace<String>('/gw').then(replacedDone.add));
          await settle(tester);
          answer = (_, _) => true;
          c.read(_wOpen.notifier).set(false);
          await settle(tester);
          expect(stackOf(r).last, '/y', reason: 'the re-run moved the page');
          r.pop('R');
          await settle(tester);
          expect(replacedDone, ['R'], reason: "the replace's Future completes");
          expect(
            pushedDone,
            isEmpty,
            reason: 'the page it opened was replaced',
          );
        });
      }
    });

    // The app's own `replace` of a pushed page keeps its page key and puts another route on it. The
    // guard of the route that stood there is no longer the page's, and a change of it does not run
    // the new route again; the guard of the new route is the page's.
    group('a page that the app replaced', () {
      testWidgets('by an unguarded one: the guard that stood there is closed', (
        tester,
      ) async {
        final r = guarded();
        final c = await start(tester, r);
        answer = (_, _) => true;
        await push(tester, r, '/g');
        unawaited(r.replace<void>('/x'));
        await settle(tester);
        expect(stackOf(r), ['/y', '/x']);
        var commits = 0;
        r.routerDelegate.addListener(() => commits++);
        final runs = gRuns;
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        c.read(_gOpen.notifier).set(true);
        await settle(tester);
        expect(commits, 0, reason: 'the page that replaced /g is not /g');
        expect(gRuns, runs, reason: 'the guard is not watched any more');
        expect(stackOf(r), ['/y', '/x']);
      });

      testWidgets('by a guarded one: only the guard of the new route is '
          'watched', (tester) async {
        final r = guarded();
        final c = await start(tester, r);
        answer = (_, _) => true;
        await push(tester, r, '/q');
        unawaited(r.replace<void>('/g'));
        await settle(tester);
        expect(stackOf(r), ['/y', '/g']);
        final runs = qRuns;
        c.read(_qOpen.notifier).set(false);
        await settle(tester);
        expect(qRuns, runs, reason: "/q's guard is not watched any more");
        expect(stackOf(r), ['/y', '/g']);
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(stackOf(r), ['/y', '/y'], reason: "/g's guard is");
      });
    });

    // The guard of a page that it moved is no longer that page's: the page shows another location,
    // and the guard changing back does not navigate it again.
    group('a page that its guard moved', () {
      for (final how in ['re-run', 'push']) {
        testWidgets('${how == 're-run' ? 'by a re-run' : 'by the push'}: a '
            'guard that changes back navigates nothing', (tester) async {
          final r = guarded();
          final c = await start(tester, r);
          answer = (_, _) => true;
          if (how == 'push') c.read(_gOpen.notifier).set(false);
          await push(tester, r, '/g');
          if (how == 're-run') {
            c.read(_gOpen.notifier).set(false);
            await settle(tester);
          }
          expect(stackOf(r), ['/y', '/y'], reason: 'the guard moved the page');
          var commits = 0;
          r.routerDelegate.addListener(() => commits++);
          final runs = gRuns;
          c.read(_gOpen.notifier).set(true);
          await settle(tester);
          expect(commits, 0, reason: 'the page that replaced /g is not /g');
          expect(gRuns, runs, reason: 'the guard is not watched any more');
          expect(stackOf(r), ['/y', '/y']);
        });
      }
    });
  });

  // The base page has a guard of its own, and a guarded page is pushed over it (fespalier/fespalier#258).
  // A change the base notices replaces the whole stack, as before 0.21.0, and the question is asked of
  // the pushed page once. A change only the pushed page's guard notices is a `refresh()` first, because
  // the base is under a redirect, and then the re-run that moves the page: a dirty page can be asked
  // twice, once for each, and at least once. docs/guards.md says so. Over an unguarded base the same
  // change is the re-run alone, and the page is asked once ('after a re-run that a leave() refused').
  group('a guarded base under a guarded pushed page', () {
    /// `/o` has a guard on the session. `/adm` has a guard on the session and one on the role
    /// (`_gOpen`), and a `leave.dart`; `/adm2` is the same with a guard that answers a microtask later.
    GoRouter orders() => GoRouter(
      initialLocation: '/y',
      navigatorKey: rootKey,
      routes: [
        GoRoute(path: '/y', builder: (_, _) => const Text('y')),
        GoRoute(path: '/in', builder: (_, _) => const Text('in')),
        leaving('/x', 'x'),
        leaving(
          '/o',
          'o',
          redirect: (context, state) => runRedirect(
            state,
            () => refGuard(
              context,
              'g1@o',
              (ref) => ref.watch(session) ? null : '/in',
            ),
          ),
        ),
        for (final isAsync in [false, true])
          leaving(
            isAsync ? '/adm2' : '/adm',
            isAsync ? 'adm2' : 'adm',
            redirect: (context, state) => runRedirect(
              state,
              () => firstRedirect([
                () => refGuard(context, 'g2@adm${isAsync ? 2 : ''}', (ref) {
                  final signedIn = ref.watch(session);
                  return signedIn ? null : '/in';
                }),
                () => refGuard(context, 'g3@adm${isAsync ? 2 : ''}', (ref) {
                  final open = ref.watch(_gOpen);
                  final answer = open ? null : '/y';
                  return isAsync ? Future<String?>.value(answer) : answer;
                }),
              ]),
            ),
          ),
      ],
    );

    /// The dirty `label` page was asked at least once and at most twice, and only about itself.
    void expectAskedOnceOrTwice(String label) {
      expect(asked.toSet(), {'$label dirty'});
      expect(asked.length, inInclusiveRange(1, 2));
    }

    List<ImperativeRouteMatch> pushed(GoRouter r) {
      final out = <ImperativeRouteMatch>[];
      pushedMatches(r.routerDelegate.currentConfiguration.matches, out);
      return out;
    }

    /// The base `/o` is shown, and the dirty `label` page is pushed over it.
    Future<ProviderContainer> over(
      WidgetTester tester,
      GoRouter r,
      String label,
    ) async {
      asked.clear();
      sources.clear();
      answer = (_, _) => true;
      final c = await pumpRouter(tester, attached(r));
      sources[label] = FakeSource(label, dirty: true);
      r.go('/o');
      await settle(tester);
      await push(tester, r, '/$label');
      expect(currentLocation(tester), '/$label');
      return c;
    }

    for (final label in ['adm', 'adm2']) {
      testWidgets('/$label: a role revoked moves the pushed page, keeps the '
          'base, and asks once or twice', (tester) async {
        final r = orders();
        final c = await over(tester, r, label);
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        // Once for the refresh, which go_router restores the page for, and once for the re-run.
        expectAskedOnceOrTwice(label);
        expect(currentLocation(tester), '/y');
        expect(pushed(r), hasLength(1));
        expect(find.text(label), findsNothing);
        expect(find.text('o', skipOffstage: false), findsOneWidget);
      });

      testWidgets('/$label: a role revoked and a question refused keeps the '
          'page, asks at most twice, and a later change is handled as usual', (
        tester,
      ) async {
        final r = orders();
        final c = await over(tester, r, label);
        answer = (_, _) => false;
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        // The refusal of the refresh's question stops the re-run: asked once, and the page stays.
        expect(asked, ['$label dirty']);
        expect(currentLocation(tester), '/$label');
        expect(find.text(label), findsOneWidget);
        // The role is back: nothing moves. The refresh the change asks for restores the page, which
        // asks it once more; it is not asked for a move, and refusing keeps it where it is.
        c.read(_gOpen.notifier).set(true);
        await settle(tester);
        expect(asked, ['$label dirty', '$label dirty']);
        expect(currentLocation(tester), '/$label');
        // Revoked again, and this time the answers let it go.
        answer = (_, _) => true;
        asked.clear();
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expectAskedOnceOrTwice(label);
        expect(currentLocation(tester), '/y');
      });

      testWidgets('/$label: a sign-out replaces the whole stack and asks '
          'once', (tester) async {
        final r = orders();
        final c = await over(tester, r, label);
        c.read(session.notifier).signedIn = false;
        await settle(tester);
        // Both pages leave, and each is asked once: the pushed page that is dirty, and the base.
        expect(asked.where((l) => l.startsWith(label)), ['$label dirty']);
        expect(asked.where((l) => l.startsWith('o')), ['o']);
        expect(currentLocation(tester), '/in');
        expect(pushed(r), isEmpty);
        expect(find.text('o', skipOffstage: false), findsNothing);
        expect(find.text(label, skipOffstage: false), findsNothing);
      });

      testWidgets('/$label: a sign-out and a question refused keeps the '
          'stack and asks once', (tester) async {
        final r = orders();
        final c = await over(tester, r, label);
        answer = (_, _) => false;
        c.read(session.notifier).signedIn = false;
        await settle(tester);
        expect(asked, ['$label dirty']);
        expect(currentLocation(tester), '/$label');
        expect(find.text(label), findsOneWidget);
      });
    }
  });
}

void otherGroups() {
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
      unawaited(leaveWithoutAsking(r, () => r.go('/y')));
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
      unawaited(leaveWithoutAsking(r, r.pop));
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
      unawaited(leaveWithoutAsking(r, r.refresh));
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

  group('a guard on the tab shell', () {
    testWidgets('runs for every tab and does not make a switch ask', (
      tester,
    ) async {
      final r = await boot(tester);
      final atBoot = shellRuns;
      answer = (_, _) => false;
      StatefulNavigationShell.of(tester.element(find.text('a'))).goBranch(1);
      await settle(tester);
      expect(find.text('b'), findsOneWidget);
      expect(shellRuns, greaterThan(atBoot), reason: 'it ran for the new tab');
      r.go('/a');
      await settle(tester);
      expect(asked, isEmpty);
      expect(find.text('a'), findsOneWidget);
    });
  });

  group('signing out through fespalier guards', () {
    for (final inbox in ['inbox', 'inbox2']) {
      for (final asyncNavigate in [false, true]) {
        testWidgets(
          'leaveWithoutAsking: /$inbox, ${asyncNavigate ? 'async' : 'sync'} sign-out',
          (tester) async {
            final r = await boot(tester, initial: '/$inbox');
            answer = (_, _) => false;
            final container = ProviderScope.containerOf(
              tester.element(find.text(inbox)),
            );
            final done = leaveWithoutAsking(r, () {
              if (asyncNavigate) {
                return Future<void>.value().then(
                  (_) => container.read(session.notifier).signedIn = false,
                );
              }
              container.read(session.notifier).signedIn = false;
              return null;
            });
            await settle(tester);
            await done;
            await settle(tester);
            expect(asked, isEmpty);
            expect(where(r), '/login');
          },
        );
      }
    }

    for (final inbox in ['inbox3', 'inbox4']) {
      testWidgets(
        'a sign-out whose destination redirects late (/$inbox) is not asked',
        (tester) async {
          final r = await boot(tester, initial: '/$inbox');
          answer = (_, _) => false;
          final container = ProviderScope.containerOf(
            tester.element(find.text(inbox)),
          );
          final done = leaveWithoutAsking(r, () {
            container.read(session.notifier).signedIn = false;
          });
          await settle(tester);
          await done;
          await settle(tester);
          expect(asked, isEmpty);
          expect(where(r), '/login');
          // The pass is gone with the commit: the next navigation asks again.
          r.go('/x');
          await settle(tester);
          r.go('/y');
          await settle(tester);
          expect(asked, ['x']);
        },
      );
    }

    testWidgets('overlapping windows give every pass back', (tester) async {
      final r = await boot(tester, initial: '/inbox2');
      answer = (_, _) => false;
      final container = ProviderScope.containerOf(
        tester.element(find.text('inbox2')),
      );
      final gate = Completer<void>();
      final first = leaveWithoutAsking(r, () async {
        await gate.future;
        container.read(session.notifier).signedIn = false;
      });
      final second = leaveWithoutAsking(r, () {});
      await settle(tester);
      await second;
      gate.complete();
      await settle(tester);
      await first;
      await settle(tester);
      expect(asked, isEmpty);
      expect(where(r), '/login');
      r.go('/x');
      await settle(tester);
      r.go('/y');
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
    });

    testWidgets('the same sign-out without leaveWithoutAsking asks', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/inbox');
      answer = (_, _) => false;
      final container = ProviderScope.containerOf(
        tester.element(find.text('inbox')),
      );
      container.read(session.notifier).signedIn = false;
      await settle(tester);
      expect(asked, ['inbox']);
      expect(where(r), '/inbox');
    });

    testWidgets('a request that commits nothing leaves no pass behind', (
      tester,
    ) async {
      final r = await boot(tester, initial: '/x');
      answer = (_, _) => false;
      final done = leaveWithoutAsking(r, () => r.go('/x'));
      await settle(tester);
      await done;
      r.go('/y');
      await settle(tester);
      expect(asked, ['x']);
      expect(find.text('x'), findsOneWidget);
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
        unawaited(leaveWithoutAsking(r, () {}));
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
    }, skip: beforeFlutter338);

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
