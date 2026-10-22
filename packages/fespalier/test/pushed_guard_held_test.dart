// A page that is held back is never asked `leave()` (invariant 3 in lib/src/guards.dart, since
// 0.21.0): its guard has not passed in a navigation that pushed it, so it was never built, and a
// question to leave a page nobody saw is a question about nothing. Its re-run may redirect, and then
// the page goes without a word.
//
// The probe I of the review of #268, kept as a test, in every order the lifecycle watch can listen in.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';

/// What the guard of `/f` does: pass, throw, or redirect to the login page.
var _mode = 'pass';

/// What each `leave()` was asked, how often the page of `/f` was built and its guard ran.
final _asked = <String>[];
var _built = 0;
var _runs = 0;

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

/// A guard that answers at once, or after a `Future` when [async].
GoRouter _router({required bool async}) => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
    GoRoute(
      path: '/f',
      redirect: (context, state) => runRedirect(
        state,
        () => refGuard(context, 'g@f', (ref) {
          _runs++;
          String? answer() => switch (_mode) {
            'throw' => throw StateError('the guard failed'),
            'redirect' => '/login',
            _ => null,
          };
          return async ? Future<String?>(answer) : answer();
        }),
      ),
      onExit: (context, state) =>
          leaveExit(context, state, 'f/leave.dart', (ref, page) {
            _asked.add('f');
            return true;
          }),
      builder: (context, state) {
        final held = refusedView(context, state);
        if (held != null) return held;
        _built++;
        return Scaffold(appBar: AppBar(), body: const Text('F'));
      },
    ),
  ],
  errorBuilder: (context, state) => routerErrorPage(
    context,
    state,
    (uri) => Text('NOT FOUND ${uri.path}'),
    guardError: (uri, error, stackTrace, retry) => const Text('ERROR'),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    _mode = 'pass';
    _asked.clear();
    _built = 0;
    _runs = 0;
  });

  inEveryOrder(() {
    for (final async in [false, true]) {
      group('a guard that ${async ? 'waits' : 'answers at once'}', () {
        /// The push of `/f` failed (its guard threw): go_router shows the entry as the page after
        /// a refresh, the page is held back, and its guard is run again.
        Future<GoRouter> refreshedAfterFailedPush(
          WidgetTester tester,
          String then,
        ) async {
          final r = _router(async: async);
          await pumpRouter(tester, attached(r));
          _mode = 'throw';
          unawaited(r.push<void>('/f'));
          await _settle(tester);
          expect(tester.takeException(), isA<StateError>());
          expect(find.text('ERROR'), findsOneWidget);
          _mode = then;
          r.refresh();
          await _settle(tester);
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          return r;
        }

        testWidgets('a held page whose re-run redirects goes without being '
            'asked', (tester) async {
          final r = await refreshedAfterFailedPush(tester, 'redirect');
          expect(_runs, greaterThan(1), reason: 'the guard ran again');
          expect(_built, 0, reason: 'it was never built');
          expect(_asked, isEmpty, reason: 'and never asked to leave');
          expect(_stack(r), ['/home', '/login']);
          expect(find.text('LOGIN'), findsOneWidget);
        });

        testWidgets('a held page whose re-run passes is built and asks '
            'nothing', (tester) async {
          final r = await refreshedAfterFailedPush(tester, 'pass');
          expect(_built, greaterThan(0));
          expect(find.text('F'), findsOneWidget);
          expect(_asked, isEmpty);
          expect(_stack(r), ['/home', '/f']);
        });
      });
    }
  });
}
