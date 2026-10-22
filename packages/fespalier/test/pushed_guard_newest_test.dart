// The newest re-run of a pushed page wins (since 0.21.0, invariant 7 in lib/src/guards.dart): a re-run
// that waits for an asynchronous guard is carried on only while it is still the newest of its entry.
// A change that starts another re-run of the page while it waits makes the first one stale, and its
// late answer must neither land over the newer one nor bring a revoked page back.
//
// The probes of the review of #268 (A and A-child), kept as tests, in every order the lifecycle
// watch can listen in.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';

class _Flag extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

/// What the guards watch: the role the pages of `/admin` and `/p/c` need.
final _role = NotifierProvider<_Flag, bool>(_Flag.new);

/// What the guard of `/p` watches: the session, which stays on.
final _session = NotifierProvider<_Flag, bool>(_Flag.new);

/// How often the guard of `/admin` and of `/p/c` ran, and what each `leave()` was asked.
var _runs = 0;
final _asked = <String>[];

/// When set, the guards answer a pass once it completes: the slow server.
Completer<void>? _server;

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

/// The guard of `/admin`: with the role gone it refuses at once (a local check, `Future.value`),
/// else it asks the slow server for a pass.
Future<String?> _adminGuard(Ref ref) {
  _runs++;
  if (!ref.watch(_role)) return Future<String?>.value('/login');
  final server = _server;
  return server == null
      ? Future<String?>.value(null)
      : server.future.then<String?>((_) => null);
}

/// How often the guard of the base page `/home` ran (see `_router`).
var _homeRuns = 0;

/// A router whose base page `/home` has no redirect, so a pushed page's guard is run again alone,
/// or, with [guardedBase], a guard of its own on the session (answered at once, or with a `Future`
/// when [asyncBase]): a sign-out is then asked of the base too.
GoRouter _router({
  bool guardedBase = false,
  bool asyncBase = false,
}) => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(
      path: '/home',
      redirect: guardedBase
          ? (context, state) => runRedirect(
              () => refGuard(context, 'g@home', (ref) {
                _homeRuns++;
                final answer = ref.watch(_session) ? null : '/login';
                return asyncBase ? Future<String?>.value(answer) : answer;
              }),
            )
          : null,
      builder: (_, _) => const Text('HOME'),
    ),
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
    GoRoute(
      path: '/x',
      builder: (_, _) => Scaffold(appBar: AppBar(), body: const Text('PAGE X')),
    ),
    GoRoute(
      path: '/admin',
      redirect: (context, state) =>
          runRedirect(() => refGuard(context, 'g@admin', _adminGuard)),
      onExit: (context, state) =>
          leaveExit(context, state, 'admin/leave.dart', (ref, page) {
            _asked.add('admin');
            return true;
          }),
      builder: (context, state) =>
          refusedView(context, state) ??
          Scaffold(appBar: AppBar(), body: const Text('ADMIN')),
    ),
    // A page whose guard waits for the server and watches the session.
    GoRoute(
      path: '/acct',
      redirect: (context, state) => runRedirect(
        () => refGuard(context, 'g@acct', (ref) {
          _runs++;
          if (!ref.watch(_session)) return Future<String?>.value('/login');
          final server = _server;
          return server == null
              ? Future<String?>.value(null)
              : server.future.then<String?>((_) => null);
        }),
      ),
      builder: (context, state) =>
          refusedView(context, state) ??
          Scaffold(appBar: AppBar(), body: const Text('ACCT')),
    ),
    // A parent whose guard passes at once and a child whose guard waits: two positions.
    GoRoute(
      path: '/p',
      redirect: (context, state) => runRedirect(
        () => refGuard(
          context,
          'g@p',
          (ref) => ref.watch(_session) ? null : '/login',
        ),
      ),
      builder: (_, _) => const Text('P'),
      routes: [
        GoRoute(
          path: 'c',
          redirect: (context, state) =>
              runRedirect(() => refGuard(context, 'g@p/c', _adminGuard)),
          builder: (context, state) =>
              refusedView(context, state) ??
              Scaffold(appBar: AppBar(), body: const Text('CHILD')),
        ),
      ],
    ),
  ],
  errorBuilder: (context, state) =>
      routerErrorPage(context, state, (uri) => Text('NOT FOUND ${uri.path}')),
);

/// What the router told the platform (the browser's history) from now on: the location and whether
/// it replaced the current entry.
typedef _Report = ({String uri, bool replace});

List<_Report> _history(WidgetTester tester) {
  final reports = <_Report>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.navigation,
    (call) async {
      if (call.method == 'routeInformationUpdated') {
        final args = call.arguments as Map<Object?, Object?>;
        reports.add((
          uri: args['uri']! as String,
          replace: args['replace']! as bool,
        ));
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
  return reports;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _push(WidgetTester tester, GoRouter r, String location) async {
  unawaited(r.push<void>(location));
  await _settle(tester);
}

void main() {
  setUp(() {
    _runs = 0;
    _homeRuns = 0;
    _asked.clear();
    _server = null;
  });

  inEveryOrder(() {
    group('a stale re-run is not carried over a newer one', () {
      /// `location` pushed, `/x` over it and popped while the server is slow: go_router shows the
      /// page again without its redirect and its guard runs again (R1), waiting for the server.
      /// Then the role is revoked, which starts a re-run of its own (R3) that the guard answers at
      /// once, and last the server answers R1's question.
      Future<GoRouter> revokedWhileWaiting(
        WidgetTester tester,
        String location,
        String text,
      ) async {
        final r = _router();
        final c = await pumpRouter(tester, attached(r));
        await _push(tester, r, location);
        await _push(tester, r, '/x');
        _server = Completer<void>();
        r.pop();
        await _settle(tester);
        expect(find.text(text), findsOneWidget, reason: 'the re-run waits');
        c.read(_role.notifier).set(false);
        await _settle(tester);
        _server!.complete();
        await _settle(tester);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        return r;
      }

      testWidgets('a role revoked while the re-run waits: the page goes', (
        tester,
      ) async {
        final r = await revokedWhileWaiting(tester, '/admin', 'ADMIN');
        expect(find.text('ADMIN'), findsNothing);
        expect(find.text('LOGIN'), findsOneWidget);
        expect(_stack(r), ['/home', '/login']);
        expect(_asked, ['admin'], reason: 'the page moved: asked once');
      });

      testWidgets('the same under a parent whose guard passes at once', (
        tester,
      ) async {
        final r = await revokedWhileWaiting(tester, '/p/c', 'CHILD');
        expect(find.text('CHILD'), findsNothing);
        expect(find.text('LOGIN'), findsOneWidget);
        expect(_stack(r), ['/home', '/login']);
      });

      testWidgets('nothing is left pending: the revoked page stays gone '
          'and a later change runs the guards of the page that is there', (
        tester,
      ) async {
        final r = await revokedWhileWaiting(tester, '/admin', 'ADMIN');
        final runs = _runs;
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(_runs, runs, reason: 'nothing runs again by itself');
        expect(_stack(r), ['/home', '/login']);
        expect(tester.takeException(), isNull);
      });

      testWidgets('without a newer re-run the carry still lands (control)', (
        tester,
      ) async {
        final r = _router();
        await pumpRouter(tester, attached(r));
        await _push(tester, r, '/admin');
        await _push(tester, r, '/x');
        _server = Completer<void>();
        r.pop();
        await _settle(tester);
        _server!.complete();
        await _settle(tester);
        expect(find.text('ADMIN'), findsOneWidget);
        expect(_stack(r), ['/home', '/admin']);
        expect(_asked, isEmpty);
      });

      testWidgets('a revoked role with no re-run in flight (control)', (
        tester,
      ) async {
        final r = _router();
        final c = await pumpRouter(tester, attached(r));
        await _push(tester, r, '/admin');
        c.read(_role.notifier).set(false);
        await _settle(tester);
        expect(_stack(r), ['/home', '/login']);
      });
    });

    group('a sign-out while a re-run waits', () {
      for (final asyncBase in [false, true]) {
        group(
          'over a base page under a ${asyncBase ? 'asynchronous' : 'synchronous'} guard',
          () {
            /// `/acct` pushed, `/x` over it and popped while the server is slow (a re-run of `/acct`
            /// waits), then the session ends and, last, the server answers.
            Future<(GoRouter, ProviderContainer)> signedOutWhileWaiting(
              WidgetTester tester,
            ) async {
              final r = _router(guardedBase: true, asyncBase: asyncBase);
              final c = await pumpRouter(tester, attached(r));
              await _push(tester, r, '/acct');
              await _push(tester, r, '/x');
              _server = Completer<void>();
              r.pop();
              await _settle(tester);
              expect(
                find.text('ACCT'),
                findsOneWidget,
                reason: 'the re-run waits',
              );
              final homeRuns = _homeRuns;
              c.read(_session.notifier).set(false);
              await _settle(tester);
              _server!.complete();
              await _settle(tester);
              for (var i = 0; i < 5; i++) {
                await tester.pump(const Duration(milliseconds: 16));
              }
              expect(
                _homeRuns,
                greaterThan(homeRuns),
                reason: 'the base was asked',
              );
              return (r, c);
            }

            testWidgets('the whole stack is replaced, as without a re-run', (
              tester,
            ) async {
              final (r, _) = await signedOutWhileWaiting(tester);
              expect(find.text('ACCT'), findsNothing);
              expect(find.text('HOME'), findsNothing);
              expect(find.text('LOGIN'), findsOneWidget);
              expect(_stack(r), ['/login']);
            });

            testWidgets('the browser history gets one new entry, as without a '
                're-run', (tester) async {
              // To report the committed stack before it refreshes, the guards tell go_router's route
              // information provider with `RouteInformationReportingType.neglect`, which the provider
              // (the same code in go_router 17.2.3 and 18.1.1) turns into
              // `SystemNavigator.routeInformationUpdated(replace: true)`: on the web the browser
              // replaces the current entry and adds none. The only entry the sign-out adds is the
              // one of its redirect, `/login`, as in the control.
              final reports = _history(tester);
              final r = _router(guardedBase: true, asyncBase: asyncBase);
              final c = await pumpRouter(tester, attached(r));
              await _push(tester, r, '/acct');
              await _push(tester, r, '/x');
              _server = Completer<void>();
              r.pop();
              await _settle(tester);
              reports.clear();
              c.read(_session.notifier).set(false);
              await _settle(tester);
              _server!.complete();
              await _settle(tester);
              final added = [
                for (final report in reports)
                  if (!report.replace) report.uri,
              ];
              expect(added, ['/login'], reason: 'reports: $reports');
              expect(_stack(r), ['/login']);
            });

            testWidgets('no re-run in flight: the same end state (control)', (
              tester,
            ) async {
              final r = _router(guardedBase: true, asyncBase: asyncBase);
              final c = await pumpRouter(tester, attached(r));
              await _push(tester, r, '/acct');
              c.read(_session.notifier).set(false);
              await _settle(tester);
              expect(_stack(r), ['/login']);
            });
          },
        );
      }
    });
  });
}
