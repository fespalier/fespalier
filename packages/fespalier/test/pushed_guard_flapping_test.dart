// A redirect of the app's own that answers differently each time it is asked must not make a
// carried re-run repeat by itself (invariant 7 in lib/src/guards.dart, since 0.21.0).
//
// A carried re-run replays the answers of the dropped one, each only to the redirect that gave it
// (same route, same location). When the app's own top-level redirect sends the carried run elsewhere,
// the guard of that place runs for real, and a late answer carries the run on once more. The second
// time along a chain that the replay meets another redirect, the run is not carried again: it lands
// as go_router lands it. Without that bound the carry would repeat on microtasks and timers with no
// user action, for as long as the redirect keeps changing its mind (the probe L of the second review
// of #268).
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';

/// How the app's own top-level redirect answers for `/admin`.
enum _Top {
  /// It does not redirect.
  off,

  /// `/secure` the first time it is asked, then not, then `/secure`, and so on.
  alternate,

  /// `/secure?n=0`, `/secure?n=1`, and so on: another location every time.
  nonce,
}

var _top = _Top.off;

/// How often the top-level redirect redirected, and how often each guard ran.
var _topCalls = 0;
var _nonce = 0;
var _adminRuns = 0;
var _secureRuns = 0;

/// How the guard of `/secure` answers: at once, after 5 ms, or with a failure.
var _secureWay = 'at once';

/// How often the router committed.
var _commits = 0;

/// When set, the guard of `/admin` answers a pass once it completes: a slow server.
Completer<void>? _server;

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

String? _topRedirect(BuildContext context, GoRouterState state) {
  if (_top == _Top.off || state.uri.path != '/admin') return null;
  _topCalls++;
  // A stop for a build without the bound: the test then fails on the count, and does not hang.
  if (_topCalls > 300) return null;
  return switch (_top) {
    _Top.alternate => _topCalls.isOdd ? '/secure' : null,
    _Top.nonce => '/secure?n=${_nonce++}',
    _Top.off => null,
  };
}

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  redirect: _topRedirect,
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    GoRoute(
      path: '/x',
      builder: (_, _) => Scaffold(appBar: AppBar(), body: const Text('PAGE X')),
    ),
    GoRoute(
      path: '/admin',
      redirect: (context, state) => runRedirect(
        state,
        () => refGuard(context, 'g@admin', (ref) {
          _adminRuns++;
          final server = _server;
          return server == null
              ? Future<String?>.value(null)
              : server.future.then<String?>((_) => null);
        }),
      ),
      builder: (context, state) =>
          refusedView(context, state) ??
          Scaffold(appBar: AppBar(), body: const Text('ADMIN')),
    ),
    GoRoute(
      path: '/secure',
      redirect: (context, state) => runRedirect(
        state,
        () => refGuard(context, 'g@secure', (ref) {
          _secureRuns++;
          return switch (_secureWay) {
            'after 5 ms' => Future<String?>.delayed(
              const Duration(milliseconds: 5),
              () => null,
            ),
            'fails' => Future<String?>.error(StateError('the guard failed')),
            _ => Future<String?>.value(null),
          };
        }),
      ),
      builder: (context, state) =>
          refusedView(context, state) ?? const Text('SECURE'),
    ),
  ],
  errorBuilder: (context, state) =>
      routerErrorPage(context, state, (uri) => Text('NOT FOUND ${uri.path}')),
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

/// Pumps [frames] frames of 16 ms.
Future<void> _frames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  setUp(() {
    _top = _Top.off;
    _topCalls = 0;
    _nonce = 0;
    _adminRuns = 0;
    _secureRuns = 0;
    _secureWay = 'at once';
    _commits = 0;
    _server = null;
  });

  inEveryOrder(() {
    for (final (top, way) in [
      (_Top.alternate, 'at once'),
      (_Top.alternate, 'after 5 ms'),
      (_Top.nonce, 'at once'),
      (_Top.nonce, 'after 5 ms'),
      (_Top.nonce, 'fails'),
    ]) {
      testWidgets('a top-level redirect that keeps changing its answer '
          '(${top.name}), the guard of the other route answers $way: the '
          'carry is bounded and the router goes quiet', (tester) async {
        final r = _router();
        await pumpRouter(tester, attached(r));
        r.routerDelegate.addListener(() => _commits++);
        await _push(tester, r, '/admin');
        await _push(tester, r, '/x');
        _server = Completer<void>();
        r.pop();
        await _settle(tester);
        expect(find.text('ADMIN'), findsOneWidget, reason: 'the re-run waits');
        // The redirect starts to answer differently each time, and the server answers.
        _secureWay = way;
        _top = top;
        _topCalls = 0;
        _server!.complete();
        await tester.pump();
        await _frames(tester, 50);
        expect(
          _topCalls,
          lessThan(5),
          reason: 'the redirect was asked $_topCalls times by one change',
        );
        final work = (_topCalls, _adminRuns, _secureRuns, _commits);
        await _frames(tester, 50);
        expect(
          (_topCalls, _adminRuns, _secureRuns, _commits),
          work,
          reason: 'nothing runs again by itself',
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
        if (way == 'fails') {
          expect(tester.takeException(), isA<StateError>());
        }
        expect(tester.takeException(), isNull);
        expect(_stack(r).first, '/home');
      });
    }

    testWidgets('the same redirect on a plain push asks it once (control)', (
      tester,
    ) async {
      final r = _router();
      await pumpRouter(tester, attached(r));
      _top = _Top.nonce;
      await _push(tester, r, '/admin');
      expect(_topCalls, lessThan(3));
      expect(_stack(r).last, startsWith('/secure'));
    });
  });
}
