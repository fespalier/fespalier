// A pushed page that the browser's back or forward brings back is held until its guard answers
// (invariant 3 in lib/src/guards.dart, since 0.21.1). go_router writes a pushed page's key into the
// history entry, so the entry of a page that is gone decodes with the key it had, and the page is
// restored without its redirect. Two things must not tell such a page from one that passed:
//
// - a page that has left for good (popped, dropped by a `go`, a tab left for good) is forgotten, so
//   its key is no pass; only the pushed pages of a tab that is not on screen are kept, because they
//   come back with the tab;
// - a pass is for the location that passed: a page that a guard or the app's `replace` moved
//   elsewhere keeps its key, and the entry of its old location is not the page that passed.
//
// - the exact location is the rule (the maintainer's decision, since 0.21.1): a page that moved by
//   its own `replace`, to another query or another parameter, and that the browser brings back at an
//   earlier address, counts as a move. It is held until its guard answers and then made again, with
//   no state, and a page whose guard said no meanwhile is never shown (probes U2, U2b and U2c of the
//   fourth review of #268). The `onLeave` and `onEnter` of its `observe.dart` run, in every order
//   the lifecycle watch can listen in (probe G).
//
// The probes P1, P1b and P1e of the third review of #268, kept as tests, in every order the
// lifecycle watch can listen in.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/guards.dart' show passedPageCount;
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';

class _Flag extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

/// What the guard of `/admin` and of `/tab/admin` watches: the role.
final _role = NotifierProvider<_Flag, bool>(_Flag.new);

/// What the guard of `/doc/1` watches besides the role: the access to that one document.
final _doc1 = NotifierProvider<_Flag, bool>(_Flag.new);

/// When non-empty, the next evaluations of a guard wait for the first of these (the slow server).
final _gates = <Completer<void>>[];

/// Whether the guards answer at once.
var _sync = false;

/// How often the page of `/admin` and of `/tab/admin` made its state, and what each `leave()` was asked.
var _built = 0;

/// How often a guard ran.
var _runs = 0;
final _asked = <String>[];

/// The tab layout's shell, and, in the nested layout, the shell inside its first tab.
StatefulNavigationShell? _shell;
StatefulNavigationShell? _inner;

/// How often an `observe.dart` `onEnter` and `onLeave` of `/admin` ran.
var _entered = 0;
var _left = 0;

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

/// The guard of a pushed page: the role decides, at once or after the next gate. The page of one
/// document (`/doc/1`) is also its own: the guard of `/doc/1` watches the access to that document.
GuardResult _guard(Ref ref, [String? id]) {
  _runs++;
  final answer = ref.watch(_role) && (id != '1' || ref.watch(_doc1))
      ? null
      : '/login';
  if (_sync) return answer;
  if (_gates.isEmpty) return Future<String?>.value(answer);
  return _gates.removeAt(0).future.then<String?>((_) => answer);
}

GoRouterRedirect _guarded(String site) => (context, state) {
  final id = state.pathParameters['id'];
  return runRedirect(
    state,
    () => refGuard(context, id == null ? site : '$site:$id', (ref) {
      return _guard(ref, id);
    }),
  );
};

GoRoute _page(String path, String site, String name, {bool counter = true}) =>
    GoRoute(
      path: path,
      redirect: _guarded(site),
      onExit: (context, state) =>
          leaveExit(context, state, '$name/leave.dart', (ref, page) {
            _asked.add(name);
            return true;
          }),
      builder: (context, state) =>
          refusedView(context, state) ??
          (counter
              ? _Counter(onState: () => _built++)
              : Scaffold(appBar: AppBar(), body: Text(name.toUpperCase()))),
    );

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
    _page('/admin', 'g@admin', 'admin'),
    // Another guarded page, of another widget: a page that it replaces does not keep its state.
    _page('/admin2', 'g@admin2', 'admin2', counter: false),
    // A page per document: `/doc/1` and `/doc/2` are the same route and two resources.
    _page('/doc/:id', 'g@doc', 'doc'),
  ],
);

/// A tab layout (`/tab` and `/other`) with a guarded page, `/tab/admin`, that the tab holds.
/// [current] is a container that builds only the branch on screen (the default, `indexedStack`,
/// keeps the other branches alive).
GoRouter _tabs({bool current = false}) {
  Widget build(BuildContext c, GoRouterState s, StatefulNavigationShell shell) {
    _shell = shell;
    return shell;
  }

  final branches = [
    StatefulShellBranch(
      routes: [
        GoRoute(
          path: '/tab',
          builder: (_, _) => const Text('TAB'),
          routes: [_page('admin', 'g@tab-admin', 'tab-admin')],
        ),
      ],
    ),
    StatefulShellBranch(
      routes: [GoRoute(path: '/other', builder: (_, _) => const Text('OTHER'))],
    ),
  ];
  return GoRouter(
    initialLocation: '/tab',
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
      current
          ? StatefulShellRoute(
              builder: build,
              navigatorContainerBuilder: (context, shell, children) =>
                  children[shell.currentIndex],
              branches: branches,
            )
          : StatefulShellRoute.indexedStack(builder: build, branches: branches),
    ],
  );
}

/// Tabs inside a tab: the first tab of the outer shell (`/a`, `/b`) is a shell of its own, and the
/// guarded page, `/b/admin`, lives in the inner shell's second tab.
GoRouter _nested() => GoRouter(
  initialLocation: '/a',
  routes: [
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) {
        _shell = shell;
        return shell;
      },
      branches: [
        StatefulShellBranch(
          routes: [
            StatefulShellRoute.indexedStack(
              builder: (context, state, shell) {
                _inner = shell;
                return shell;
              },
              branches: [
                StatefulShellBranch(
                  routes: [
                    GoRoute(path: '/a', builder: (_, _) => const Text('A')),
                  ],
                ),
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/b',
                      builder: (_, _) => const Text('B'),
                      routes: [_page('admin', 'g@b-admin', 'b-admin')],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/other', builder: (_, _) => const Text('OTHER')),
          ],
        ),
      ],
    ),
  ],
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _push(WidgetTester tester, GoRouter r, String location) async {
  unawaited(r.push<void>(location));
  await _settle(tester);
}

/// Whether the readers of a held page say the page on top is held: the page's gate (`refusedView`
/// and `leave()` ask the key) and the walk of the lifecycle watch and of DevTools (they ask the entry).
({bool gate, bool walk}) _readers(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return (
    gate: isHeldPage(r, pushed.last.pageKey),
    walk: refusedEntry(r, pushed.last),
  );
}

/// What the screen shows of the counter page: built and visible, or not.
String _shown() =>
    '${find.text('COUNT 0').evaluate().length + find.text('COUNT 1').evaluate().length}';

/// Restores [entry], a history entry saved earlier, as the browser's back or forward does; an
/// asynchronous guard waits for the returned gate. Returns how often the page was built in the first
/// frame ([first]: a held page is not built yet, whatever its guard answers) and by the time the
/// router settled with the gate still shut ([built]), and whether the page was on screen then.
Future<({int first, int built, String shown, Completer<void>? gate})> _restore(
  WidgetTester tester,
  GoRouter r,
  RouteInformation entry,
) async {
  final gate = _sync ? null : Completer<void>();
  if (gate != null) _gates.add(gate);
  final before = _built;
  unawaited(r.routeInformationProvider.didPushRouteInformation(entry));
  await tester.pump();
  final first = _built - before;
  await _settle(tester);
  return (first: first, built: _built - before, shown: _shown(), gate: gate);
}

void main() {
  setUp(() {
    _gates.clear();
    _sync = false;
    _built = 0;
    _runs = 0;
    _asked.clear();
    _shell = null;
    _inner = null;
    _entered = 0;
    _left = 0;
  });

  inEveryOrder(() {
    for (final sync in [true, false]) {
      group('a guard that ${sync ? 'answers at once' : 'waits'}', () {
        setUp(() => _sync = sync);

        testWidgets('a popped page that the browser brings back after its '
            'role was revoked is not built, and not entered', (tester) async {
          final r = _router();
          final c = await pumpRouter(tester, attached(r));
          await _push(tester, r, '/admin');
          expect(find.text('COUNT 0'), findsOneWidget);
          final entry = r.routeInformationProvider.value;
          r.pop();
          await _settle(tester);
          expect(_stack(r), ['/home']);
          c.read(_role.notifier).set(false);
          await _settle(tester);
          _asked.clear();

          final back = await _restore(tester, r, entry);
          expect(back.first, 0, reason: 'its guard has not answered yet');
          if (!sync) {
            expect(back.built, 0);
            expect(_stack(r), ['/home', '/admin'], reason: 'it waits held');
            expect(back.shown, '0');
            expect(_readers(r), (gate: true, walk: true), reason: 'they agree');
          }
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r), ['/home', '/login']);
          expect(_built, 1, reason: 'the page was never made again');
          expect(
            _asked,
            isEmpty,
            reason: 'a held page goes without a question',
          );
        });

        testWidgets('a popped page that the browser brings back while its '
            'role holds is held until the guard answers', (tester) async {
          final r = _router();
          await pumpRouter(tester, attached(r));
          await _push(tester, r, '/admin');
          final entry = r.routeInformationProvider.value;
          r.pop();
          await _settle(tester);

          final back = await _restore(tester, r, entry);
          expect(back.first, 0, reason: 'held until the guard answers');
          if (!sync) {
            expect(back.built, 0, reason: 'held while the guard waits');
            expect(back.shown, '0');
            expect(_readers(r), (gate: true, walk: true), reason: 'they agree');
          }
          back.gate?.complete();
          await _settle(tester);
          expect(_readers(r), (gate: false, walk: false), reason: 'it passed');
          expect(_stack(r), ['/home', '/admin']);
          expect(find.text('COUNT 0'), findsOneWidget);
          expect(_built, 2);
        });

        testWidgets('a page that `go` dropped and the browser brings back is '
            'held', (tester) async {
          final r = _router();
          final c = await pumpRouter(tester, attached(r));
          await _push(tester, r, '/admin');
          final entry = r.routeInformationProvider.value;
          r.go('/login');
          await _settle(tester);
          expect(_stack(r), ['/login']);
          c.read(_role.notifier).set(false);
          await _settle(tester);

          final back = await _restore(tester, r, entry);
          expect(back.built, 0);
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r).last, '/login');
          expect(_built, 1);
        });

        testWidgets('a page that its guard moved, and the browser brings its '
            'old entry back, is held', (tester) async {
          final r = _router();
          final c = await pumpRouter(tester, attached(r));
          await _push(tester, r, '/admin');
          final entry = r.routeInformationProvider.value;
          // The role goes: the re-run moves the page to `/login`, and the page keeps its key.
          c.read(_role.notifier).set(false);
          await _settle(tester);
          expect(_stack(r), ['/home', '/login']);
          expect(_built, 1);

          final back = await _restore(tester, r, entry);
          expect(
            back.built,
            0,
            reason: 'the entry is not the page that passed',
          );
          if (!sync) {
            expect(back.shown, '0');
            expect(_readers(r), (gate: true, walk: true), reason: 'they agree');
          }
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r), ['/home', '/login']);
          expect(_built, 1);
        });

        testWidgets('a page that the app replaced, and the browser brings its '
            'old entry back, is held', (tester) async {
          final r = _router();
          await pumpRouter(tester, attached(r));
          await _push(tester, r, '/admin');
          final entry = r.routeInformationProvider.value;
          unawaited(r.replace<void>('/admin2'));
          await _settle(tester);
          expect(_stack(r), ['/home', '/admin2']);
          expect(find.text('ADMIN2'), findsOneWidget);
          expect(_built, 1);

          final back = await _restore(tester, r, entry);
          expect(
            back.first,
            0,
            reason: 'the page that passed is `/admin2` now',
          );
          expect(back.built, sync ? 1 : 0, reason: 'then its guard passes');
          if (!sync) {
            expect(back.shown, '0');
            expect(_readers(r), (gate: true, walk: true), reason: 'they agree');
          }
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r), ['/home', '/admin']);
          expect(find.text('COUNT 0'), findsOneWidget);
          expect(_built, 2);
        });

        // The exact location is the rule. A page that changed its own query with `replace` (a search
        // box over a pushed page) is at another address when the browser brings an older one back:
        // that is a move, whatever the page is called.
        testWidgets('a page that replaced itself with other queries, and the '
            'browser brings an earlier query back, is held and made again', (
          tester,
        ) async {
          final r = _router();
          await pumpRouter(tester, attached(r));
          await _push(tester, r, '/admin?q=0');
          await tester.tap(find.textContaining('COUNT'));
          await tester.pump();
          final entries = [r.routeInformationProvider.value];
          for (var i = 1; i <= 3; i++) {
            unawaited(r.replace<void>('/admin?q=$i'));
            await _settle(tester);
            entries.add(r.routeInformationProvider.value);
          }
          expect(
            find.text('COUNT 1'),
            findsOneWidget,
            reason: 'a replace keeps the page and its state',
          );
          expect(_built, 1);
          final runs = _runs;

          final back = await _restore(tester, r, entries[1]);
          expect(back.first, 0, reason: 'held whatever its guard answers');
          if (!sync) {
            expect(back.built, 0);
            expect(back.shown, '0', reason: 'an empty box while it waits');
            expect(_stack(r), ['/home', '/admin?q=1']);
            expect(_readers(r), (gate: true, walk: true), reason: 'they agree');
          }
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r), ['/home', '/admin?q=1']);
          expect(
            find.text('COUNT 0'),
            findsOneWidget,
            reason: 'made again from scratch: its state is lost',
          );
          expect(_built, 2);
          expect(_runs - runs, 1, reason: 'its guard ran once');
          expect(_readers(r), (gate: false, walk: false), reason: 'it passed');

          // Forward to the latest query is the same move.
          final forward = await _restore(tester, r, entries[3]);
          expect(forward.first, 0);
          if (!sync) expect(forward.shown, '0');
          forward.gate?.complete();
          await _settle(tester);
          expect(_stack(r), ['/home', '/admin?q=3']);
          expect(find.text('COUNT 0'), findsOneWidget);
          expect(_built, 3);
          expect(_runs - runs, 2);
        });

        for (final revoke in [false, true]) {
          testWidgets('a page that replaced itself with another parameter, and '
              'the browser brings the first back, is held and made again '
              '[role revoked meanwhile: $revoke]', (tester) async {
            final r = _router();
            final c = await pumpRouter(tester, attached(r));
            await _push(tester, r, '/doc/1');
            await tester.tap(find.textContaining('COUNT'));
            await tester.pump();
            final first = r.routeInformationProvider.value;
            unawaited(r.replace<void>('/doc/2'));
            await _settle(tester);
            expect(find.text('COUNT 1'), findsOneWidget, reason: 'same page');
            if (revoke) {
              // The page that stands there moves to `/login`.
              c.read(_role.notifier).set(false);
              await _settle(tester);
              expect(_stack(r), ['/home', '/login']);
            }
            final runs = _runs;

            final back = await _restore(tester, r, first);
            expect(back.first, 0, reason: 'held whatever its guard answers');
            if (!sync) {
              expect(back.built, 0);
              expect(back.shown, '0');
              expect(_stack(r), ['/home', '/doc/1']);
            }
            back.gate?.complete();
            await _settle(tester);
            expect(_runs - runs, 1, reason: 'its guard ran once');
            if (revoke) {
              expect(_stack(r), ['/home', '/login']);
              expect(find.text('LOGIN'), findsOneWidget);
              expect(_built, 1, reason: 'never made again, never shown');
            } else {
              expect(_stack(r), ['/home', '/doc/1']);
              expect(find.text('COUNT 0'), findsOneWidget);
              expect(_built, 2, reason: 'made again from scratch');
            }
          });
        }

        // A guard that is about one resource (`/doc/1`) has its own answer. The page left `/doc/1` for
        // `/doc/2`, so nothing watches the access to `/doc/1` any more, and revoking it runs nothing.
        // The browser's back to the older entry must not show the document the person may no longer
        // read, not even for the first frame or the whole wait of a slow guard.
        testWidgets('a document whose access was revoked while the page showed '
            'another one is never shown when the browser brings it back', (
          tester,
        ) async {
          final r = _router();
          final c = await pumpRouter(tester, attached(r));
          await _push(tester, r, '/doc/1');
          await tester.tap(find.textContaining('COUNT'));
          await tester.pump();
          final first = r.routeInformationProvider.value;
          unawaited(r.replace<void>('/doc/2'));
          await _settle(tester);
          c.read(_doc1.notifier).set(false);
          await _settle(tester);
          expect(_stack(r), ['/home', '/doc/2'], reason: 'nothing watched it');
          expect(find.text('COUNT 1'), findsOneWidget);
          _asked.clear();

          final back = await _restore(tester, r, first);
          expect(back.first, 0);
          expect(back.built, 0, reason: 'never built, so never shown');
          if (!sync) {
            expect(back.shown, '0');
            expect(_stack(r), ['/home', '/doc/1']);
            expect(_readers(r), (gate: true, walk: true), reason: 'they agree');
          }
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r), ['/home', '/login']);
          expect(find.textContaining('COUNT'), findsNothing);
          expect(_built, 1, reason: 'the page was never made again');
        });

        testWidgets('a page of a tab that was left for good is held when the '
            'browser brings it back', (tester) async {
          final r = _tabs();
          await pumpRouter(tester, attached(r));
          await _push(tester, r, '/tab/admin');
          final entry = r.routeInformationProvider.value;
          _shell!.goBranch(1);
          await _settle(tester);
          r.go('/login');
          await _settle(tester);

          final back = await _restore(tester, r, entry);
          expect(back.first, 0);
          expect(back.built, sync ? 1 : 0, reason: 'then its guard passes');
          if (!sync) {
            expect(back.shown, '0');
            expect(_readers(r), (gate: true, walk: true), reason: 'they agree');
          }
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r).last, '/tab/admin');
          expect(find.text('COUNT 0'), findsOneWidget);
          expect(_built, 2);
        });

        for (final keeps in [true, false]) {
          testWidgets(
            'a page of a parked tab comes back with its state when the '
            'container keeps its branches, and is made again when it builds '
            'only the branch on screen [keeps branches: $keeps]',
            (tester) async {
              final r = _tabs(current: !keeps);
              await pumpRouter(tester, attached(r));
              await _push(tester, r, '/tab/admin');
              await tester.tap(find.textContaining('COUNT'));
              await tester.pump();
              expect(find.text('COUNT 1'), findsOneWidget);
              _shell!.goBranch(1);
              await _settle(tester);
              expect(passedPageCount(r), 1, reason: 'its tab is parked');
              _shell!.goBranch(0);
              await _settle(tester);
              expect(_stack(r).last, '/tab/admin');
              expect(find.text(keeps ? 'COUNT 1' : 'COUNT 0'), findsOneWidget);
              expect(_built, keeps ? 1 : 2);
            },
          );
        }

        testWidgets('a page of a tab inside a parked tab is kept with its state '
            'and not held when the tabs come back', (tester) async {
          final r = _nested();
          await pumpRouter(tester, attached(r));
          _inner!.goBranch(1);
          await _settle(tester);
          expect(find.text('B'), findsOneWidget);
          await _push(tester, r, '/b/admin');
          await tester.tap(find.text('COUNT 0'));
          await tester.pump();
          expect(find.text('COUNT 1'), findsOneWidget);
          _shell!.goBranch(1);
          await _settle(tester);
          expect(find.text('OTHER'), findsOneWidget);
          expect(
            passedPageCount(r),
            1,
            reason: 'the inner shell is not on screen, its tab is parked',
          );
          // The tab comes back: go_router restores the page without its redirect, and the guard
          // waits (when it does) with the page on screen.
          final gate = _sync ? null : Completer<void>();
          if (gate != null) _gates.add(gate);
          _shell!.goBranch(0);
          await _settle(tester);
          expect(
            find.text('COUNT 1'),
            findsOneWidget,
            reason: 'the page passed before and is back with its tab',
          );
          gate?.complete();
          await _settle(tester);
          expect(find.text('COUNT 1'), findsOneWidget);
          expect(_built, 1, reason: 'the page was never made again');
        });

        testWidgets(
          'the passed pages are the guarded pages that can come back: '
          'popped, dropped and left-for-good pages are forgotten',
          (tester) async {
            final r = _router();
            await pumpRouter(tester, attached(r));
            for (var i = 0; i < 12; i++) {
              await _push(tester, r, '/admin');
              if (i.isEven) await _push(tester, r, '/admin2');
              expect(passedPageCount(r), i.isEven ? 2 : 1);
              r.pop();
              await _settle(tester);
              if (i.isEven) {
                r.pop();
                await _settle(tester);
              }
              expect(passedPageCount(r), 0);
            }
            await _push(tester, r, '/admin');
            r.go('/login');
            await _settle(tester);
            expect(passedPageCount(r), 0, reason: 'dropped by a go');
          },
        );

        testWidgets('a page of a parked tab is remembered until the tab is '
            'left for good', (tester) async {
          final r = _tabs();
          await pumpRouter(tester, attached(r));
          expect(passedPageCount(r), 0);
          await _push(tester, r, '/tab/admin');
          expect(passedPageCount(r), 1);
          _shell!.goBranch(1);
          await _settle(tester);
          expect(
            passedPageCount(r),
            1,
            reason: 'the tab is parked, and its page comes back with it',
          );
          _shell!.goBranch(0);
          await _settle(tester);
          expect(passedPageCount(r), 1);
          _shell!.goBranch(1);
          await _settle(tester);
          r.go('/login');
          await _settle(tester);
          expect(passedPageCount(r), 0, reason: 'the tabs are gone');
        });
      });
    }
  });

  // The `onEnter` of an `observe.dart` is not run for a held page. The lifecycle watch is attached by
  // the test, before or after the Router widget is built, so the order that attaches it is the
  // test's.
  inEveryOrder(
    orders: [AttachFirst.nothing, AttachFirst.devTools, AttachFirst.telemetry],
    () {
      for (final sync in [true, false]) {
        for (final observeFirst in [true, false]) {
          testWidgets('a popped page that the browser brings back is not '
              'entered [sync=$sync, observe first=$observeFirst]', (
            tester,
          ) async {
            _sync = sync;
            final r = _router();
            List<RouteHooks> hooks(Uri uri) => uri.path == '/admin'
                ? [
                    RouteHooks(
                      'admin/observe.dart',
                      onEnter: (ref, scope) => _entered++,
                    ),
                  ]
                : const [];
            if (observeFirst) observeAttach(r, hooks);
            attached(r);
            final c = await pumpRouter(tester, r);
            if (!observeFirst) observeAttach(r, hooks);
            await _push(tester, r, '/admin');
            final entry = r.routeInformationProvider.value;
            r.pop();
            await _settle(tester);
            c.read(_role.notifier).set(false);
            await _settle(tester);
            final entered = _entered;

            final back = await _restore(tester, r, entry);
            expect(_entered, entered, reason: 'held while the guard waits');
            back.gate?.complete();
            await _settle(tester);
            expect(_entered, entered, reason: 'and sent to `/login` unseen');
            expect(_stack(r), ['/home', '/login']);
          });
        }
      }
    },
  );

  // The page that the browser brings back at an earlier address of its own `replace` is held, so
  // its State is made again in every order. Its `observe.dart` hooks say the same: `onLeave` runs
  // when the page is held (the first frame that shows the box), `onEnter` when the page that was
  // made again shows. Whichever reader of the commit listens first, and wherever the test attaches
  // the lifecycle watch, they run once each (probe G of the fourth review of #268: a synchronous
  // guard ran neither when DevTools or telemetry judged the commit before the watch registered its
  // report, because the guard's re-run was registered before it and landed first).
  inEveryOrder(
    orders: [AttachFirst.nothing, AttachFirst.devTools, AttachFirst.telemetry],
    () {
      for (final sync in [true, false]) {
        for (final at in _ObserveAt.values) {
          testWidgets('the hooks of a page that the browser brings back across '
              'its own replace agree [sync=$sync, observe ${at.name}]', (
            tester,
          ) async {
            _sync = sync;
            final r = _router();
            List<RouteHooks> hooks(Uri uri) => uri.path == '/admin'
                ? [
                    RouteHooks(
                      'admin/observe.dart',
                      onEnter: (ref, scope) => _entered++,
                      onLeave: (ref) => _left++,
                    ),
                  ]
                : const [];
            if (at == _ObserveAt.before) observeAttach(r, hooks);
            attached(r);
            if (at == _ObserveAt.between) observeAttach(r, hooks);
            await pumpRouter(tester, r);
            if (at == _ObserveAt.after) observeAttach(r, hooks);
            await _push(tester, r, '/admin?q=0');
            await tester.tap(find.textContaining('COUNT'));
            await tester.pump();
            final first = r.routeInformationProvider.value;
            unawaited(r.replace<void>('/admin?q=1'));
            await _settle(tester);
            expect(
              (_entered, _left),
              (1, 0),
              reason: 'a replace is the same page',
            );

            final back = await _restore(tester, r, first);
            if (!sync) {
              expect(
                (_entered, _left),
                (1, 1),
                reason: 'held: the page is not on screen while the guard waits',
              );
            }
            back.gate?.complete();
            await _settle(tester);
            expect(find.text('COUNT 0'), findsOneWidget, reason: 'made again');
            expect(_built, 2);
            expect(
              (_entered, _left),
              (2, 1),
              reason: 'left once, entered again',
            );

            final current = FespalierTelemetry.current;
            if (current is RecordingTelemetry) {
              expect(
                [
                  for (final line in current.log)
                    if (line.contains(' page ') && line.endsWith(' /admin'))
                      line.split(' ')[2],
                ],
                ['enter', 'leave', 'enter'],
                reason: 'telemetry hears the same page events',
              );
            }
          });
        }
      }
    },
  );
}

/// A page with state of its own: a tap on its text counts, and [onState] hears each time the state
/// is made.
final class _Counter extends StatefulWidget {
  const _Counter({required this.onState});

  final VoidCallback onState;

  @override
  State<_Counter> createState() => _CounterState();
}

final class _CounterState extends State<_Counter> {
  var count = 0;

  @override
  void initState() {
    super.initState();
    widget.onState();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: GestureDetector(
      onTap: () => setState(() => count++),
      child: Text('COUNT $count'),
    ),
  );
}

/// Where a test attaches the lifecycle watch: before everything else that listens to the router,
/// after that and before the Router widget is built, or after the widget is built.
enum _ObserveAt { before, between, after }
