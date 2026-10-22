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

/// When non-empty, the next evaluations of a guard wait for the first of these (the slow server).
final _gates = <Completer<void>>[];

/// Whether the guards answer at once.
var _sync = false;

/// How often the page of `/admin` and of `/tab/admin` made its state, and what each `leave()` was asked.
var _built = 0;
final _asked = <String>[];

/// The tab layout's shell.
StatefulNavigationShell? _shell;

/// How often an `observe.dart` `onEnter` of `/admin` ran.
var _entered = 0;

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

/// The guard of a pushed page: the role decides, at once or after the next gate.
GuardResult _guard(Ref ref) {
  final answer = ref.watch(_role) ? null : '/login';
  if (_sync) return answer;
  if (_gates.isEmpty) return Future<String?>.value(answer);
  return _gates.removeAt(0).future.then<String?>((_) => answer);
}

GoRouterRedirect _guarded(String site) =>
    (context, state) =>
        runRedirect(state, () => refGuard(context, site, _guard));

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
  ],
);

/// A tab layout (`/tab` and `/other`) with a guarded page, `/tab/admin`, that the tab holds.
GoRouter _tabs() => GoRouter(
  initialLocation: '/tab',
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
            GoRoute(
              path: '/tab',
              builder: (_, _) => const Text('TAB'),
              routes: [_page('admin', 'g@tab-admin', 'tab-admin')],
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
    _asked.clear();
    _shell = null;
    _entered = 0;
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
          }
          back.gate?.complete();
          await _settle(tester);
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
          if (!sync) expect(back.shown, '0');
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
          if (!sync) expect(back.shown, '0');
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r), ['/home', '/admin']);
          expect(find.text('COUNT 0'), findsOneWidget);
          expect(_built, 2);
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
          if (!sync) expect(back.shown, '0');
          back.gate?.complete();
          await _settle(tester);
          expect(_stack(r).last, '/tab/admin');
          expect(find.text('COUNT 0'), findsOneWidget);
          expect(_built, 2);
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
