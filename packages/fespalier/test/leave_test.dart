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

Widget page(String label) => Scaffold(body: Center(child: Text(label)));

/// What the generator writes for a folder with a leave.dart: `onExit` and the page wrapper.
GoRoute leaving(
  String path,
  String label, {
  List<RouteBase> routes = const [],
  String Function(GoRouterState state)? labelOf,
  GoRouterRedirect? redirect,
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

/// Whether the guard of `/g` lets it through: a re-run after a change asks the guard again.
final class _GOpen extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

final _gOpen = NotifierProvider<_GOpen, bool>(_GOpen.new);

/// Whether the guard of `/q` lets it through: a guard of its own, that `_gOpen` has nothing to do with.
final _qOpen = NotifierProvider<_GOpen, bool>(_GOpen.new);

void main() {
  // A guard's re-run of a pushed page (since 0.21.0) asks `leave()` as a base page's redirect does:
  // nothing when the guard passes again (the page is replaced by itself), the question when it
  // moves the page. The base page's side is in 'signing out through fespalier guards' below.
  group('a re-run of a guarded pushed page (fespalier/fespalier#258)', () {
    var gRuns = 0;

    /// How often the guard of `/q` ran: a guard of its own, that no change of `_gOpen` concerns.
    var qRuns = 0;

    /// When set, the guard of `/g4` answers once it completes: a guard that takes a while.
    Completer<void>? gGate;

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
            () => refGuard(context, 'q1@q', (ref) {
              qRuns++;
              return ref.watch(_qOpen) ? null : '/y';
            }),
          ),
        ),
        leaving(
          '/g4',
          'g4',
          redirect: (context, state) => runRedirect(
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
      answer = (_, _) => false;
      return pumpRouter(tester, r);
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
  });

  // The base page has a guard of its own, and a guarded page is pushed over it (fespalier/fespalier#258):
  // one question per move the person sees. A change the base notices replaces the whole stack, and the
  // question is asked of the pushed page once; a change only the pushed page's guard notices moves
  // that page, and asks once, whatever the base is.
  group('a guarded base under a guarded pushed page asks once', () {
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
      final c = await pumpRouter(tester, r);
      sources[label] = FakeSource(label, dirty: true);
      r.go('/o');
      await settle(tester);
      await push(tester, r, '/$label');
      expect(currentLocation(tester), '/$label');
      return c;
    }

    for (final label in ['adm', 'adm2']) {
      testWidgets('/$label: a role revoked moves the pushed page, keeps the '
          'base and asks once', (tester) async {
        final r = orders();
        final c = await over(tester, r, label);
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(asked, ['$label dirty']);
        expect(currentLocation(tester), '/y');
        expect(pushed(r), hasLength(1));
        expect(find.text(label), findsNothing);
        expect(find.text('o', skipOffstage: false), findsOneWidget);
      });

      testWidgets('/$label: a role revoked and a question refused keeps the '
          'page, asks once, and a later change is handled as usual', (
        tester,
      ) async {
        final r = orders();
        final c = await over(tester, r, label);
        answer = (_, _) => false;
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(asked, ['$label dirty']);
        expect(currentLocation(tester), '/$label');
        expect(find.text(label), findsOneWidget);
        // The role is back: the guard passes, and nothing is asked.
        c.read(_gOpen.notifier).set(true);
        await settle(tester);
        expect(asked, ['$label dirty']);
        expect(currentLocation(tester), '/$label');
        // Revoked again: a move of its own, asked once more, and this time it goes.
        answer = (_, _) => true;
        c.read(_gOpen.notifier).set(false);
        await settle(tester);
        expect(asked, ['$label dirty', '$label dirty']);
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
