// A guard that answers with a Future re-runs a pushed page (since 0.21.0): the re-run is dropped at
// that answer, never landed, and carried on by a new re-run that replays the answers received so far
// by position, so its landing has all of them when `leave()` is asked. Carried only while the entry the
// first re-run was about is still on top (invariant 7 in lib/src/guards.dart).
import 'dart:async';

import 'package:fespalier/fespalier.dart';
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

/// What the guards of `/slow`, `/p` and `/chain` watch: a session, and a role.
final _session = NotifierProvider<_Flag, bool>(_Flag.new);
final _role = NotifierProvider<_Flag, bool>(_Flag.new);

/// How often each guard ran, and how often the page of `/slow` was built from scratch.
var _slowRuns = 0;
var _chain1Runs = 0;
var _chain2Runs = 0;
var _parentRuns = 0;
var _childRuns = 0;
var _states = 0;

/// When set, the asynchronous guards answer once it completes.
Completer<void>? _gate;

/// What each `leave()` was asked, and what it answers.
final _asked = <String>[];
var _allow = true;

/// How often the router committed since a test began to count.
var _commitsSeen = 0;

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

/// An asynchronous answer: immediate, or once [_gate] completes.
Future<String?> _answer(String? location) {
  final wait = _gate;
  return wait == null
      ? Future<String?>.value(location)
      : wait.future.then<String?>((_) => location);
}

FutureOr<bool> _leave(String label) {
  _asked.add(label);
  return _allow;
}

GoRouter _router() => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
    GoRoute(
      path: '/x',
      builder: (_, _) => Scaffold(appBar: AppBar(), body: const Text('PAGE X')),
    ),
    // An asynchronous guard, a `leave()`, and a page with state.
    GoRoute(
      path: '/slow',
      redirect: (context, state) => runRedirect(
        () => refGuard(context, 'g@slow', (ref) {
          _slowRuns++;
          return _answer(ref.watch(_session) ? null : '/login');
        }),
      ),
      onExit: (context, state) =>
          leaveExit(context, state, 'slow/leave.dart', (ref, page) {
            return _leave('slow');
          }),
      builder: (context, state) =>
          refusedView(context, state) ??
          Scaffold(
            appBar: AppBar(),
            body: _Counter(onState: () => _states++),
          ),
    ),
    // One redirect that chains two guards, as the generator writes it: the second runs after the
    // first one's answer, outside the call of the re-run.
    GoRoute(
      path: '/chain',
      redirect: (context, state) => runRedirect(
        () => firstRedirect([
          () => refGuard(context, 'g1@chain', (ref) {
            _chain1Runs++;
            return _answer(null);
          }),
          () => refGuard(context, 'g2@chain', (ref) {
            _chain2Runs++;
            return ref.watch(_role) ? null : '/login';
          }),
        ]),
      ),
      builder: (context, state) =>
          refusedView(context, state) ??
          Scaffold(appBar: AppBar(), body: const Text('CHAIN')),
    ),
    // A parent with a synchronous guard, a child with an asynchronous one: the redirects of the
    // chain are told by their position.
    GoRoute(
      path: '/p',
      redirect: (context, state) => runRedirect(
        () => refGuard(context, 'g@p', (ref) {
          _parentRuns++;
          return ref.watch(_session) ? null : '/login';
        }),
      ),
      builder: (_, _) => const Text('P'),
      routes: [
        GoRoute(
          path: 'c',
          redirect: (context, state) => runRedirect(
            () => refGuard(context, 'g@p/c', (ref) {
              _childRuns++;
              return _answer(ref.watch(_role) ? null : '/login');
            }),
          ),
          builder: (context, state) =>
              refusedView(context, state) ??
              Scaffold(appBar: AppBar(), body: const Text('CHILD')),
        ),
      ],
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

Future<void> _push(WidgetTester tester, GoRouter r, String location) async {
  unawaited(r.push<void>(location));
  await _settle(tester);
}

void main() {
  setUp(() {
    _slowRuns = _chain1Runs = _chain2Runs = _parentRuns = _childRuns = 0;
    _states = 0;
    _gate = null;
    _asked.clear();
    _allow = true;
    _commitsSeen = 0;
  });

  inEveryOrder(() {
    group('an asynchronous re-run is dropped at its answer and carried on', () {
      /// `/slow` pushed, `/x` over it and popped, with the guard of `/slow` waiting for the gate:
      /// go_router shows `/slow` again without its redirect, and its guard runs again.
      Future<(GoRouter, ProviderContainer)> waiting(WidgetTester tester) async {
        final r = _router();
        final c = await pumpRouter(tester, attached(r));
        await _push(tester, r, '/slow');
        await tester.tap(find.text('COUNT 0'));
        await tester.pump();
        await _push(tester, r, '/x');
        c.read(_session.notifier).set(true);
        _gate = Completer<void>();
        final runs = _slowRuns;
        r.pop();
        await _settle(tester);
        expect(_slowRuns, runs + 1, reason: 'the re-run started');
        expect(find.text('COUNT 1'), findsOneWidget, reason: 'the old page');
        r.routerDelegate.addListener(() => _commitsSeen++);
        return (r, c);
      }

      testWidgets('a guard that passes: one landing, the guard run once, '
          'nothing asked and the page keeps its state', (tester) async {
        final (r, _) = await waiting(tester);
        final runs = _slowRuns;
        _gate!.complete();
        await _settle(tester);
        expect(_commitsSeen, 1, reason: 'the landing of the replay alone');
        expect(_slowRuns, runs, reason: 'the replay asked no guard again');
        expect(_asked, isEmpty);
        expect(find.text('COUNT 1'), findsOneWidget);
        expect(_states, 1, reason: 'the page was never made again');
        expect(_stack(r), ['/home', '/slow']);
        expect(tester.binding.hasScheduledFrame, isFalse);
      });

      testWidgets('a guard that moves the page: asked once at the landing, '
          'and a yes moves it', (tester) async {
        final (r, c) = await waiting(tester);
        c.read(_session.notifier).set(false);
        await _settle(tester);
        _gate!.complete();
        await _settle(tester);
        expect(_asked, ['slow']);
        expect(_stack(r), ['/home', '/login']);
        expect(find.text('LOGIN'), findsOneWidget);
      });

      testWidgets('a guard that moves the page: a no keeps the page and its '
          'guard', (tester) async {
        final (r, c) = await waiting(tester);
        c.read(_session.notifier).set(false);
        await _settle(tester);
        _allow = false;
        _gate!.complete();
        await _settle(tester);
        expect(_asked, ['slow']);
        expect(_stack(r), ['/home', '/slow']);
        expect(find.text('COUNT 1'), findsOneWidget);
        // Nothing asks again by itself, and the guard passing again asks nothing.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(_asked, ['slow']);
        c.read(_session.notifier).set(true);
        await _settle(tester);
        expect(_asked, ['slow']);
        expect(_stack(r), ['/home', '/slow']);
      });

      testWidgets('a guard that fails: the error view, reported once', (
        tester,
      ) async {
        final (r, _) = await waiting(tester);
        _gate!.completeError(StateError('the guard failed'));
        await _settle(tester);
        expect(tester.takeException(), isA<StateError>());
        expect(find.text('ERROR'), findsOneWidget);
        expect(find.text('COUNT 1'), findsNothing);
        expect(_stack(r), ['/home', '/slow']);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'reported once');
      });

      for (final way in ['pop', 'go', 'push', 'refresh']) {
        testWidgets('$way before the guard answers: the entry is gone, '
            'nothing is carried and nothing comes back', (tester) async {
          final (r, _) = await waiting(tester);
          switch (way) {
            case 'pop':
              r.pop();
            case 'go':
              r.go('/home');
            case 'push':
              unawaited(r.push<void>('/x'));
            case 'refresh':
              r.refresh();
          }
          await _settle(tester);
          final stack = _stack(r);
          final runs = _slowRuns;
          final asked = [..._asked];
          _commitsSeen = 0;
          _gate!.complete();
          await _settle(tester);
          expect(_stack(r), stack, reason: 'the late answer changed nothing');
          if (way != 'refresh') {
            expect(_commitsSeen, 0, reason: 'and committed nothing');
            expect(_slowRuns, runs);
          }
          expect(_asked, asked, reason: 'and asked nothing');
          expect(tester.takeException(), isNull);
        });
      }
    });

    group('the redirects of the replay are told by their position', () {
      testWidgets('the second guard of a chain, evaluated after the first '
          'one answered, is watched after the landing', (tester) async {
        final r = _router();
        final c = await pumpRouter(tester, attached(r));
        await _push(tester, r, '/chain');
        await _push(tester, r, '/x');
        _gate = Completer<void>();
        final before = (_chain1Runs, _chain2Runs);
        r.pop();
        await _settle(tester);
        expect(find.text('CHAIN'), findsOneWidget, reason: 'still waiting');
        _gate!.complete();
        await _settle(tester);
        expect(find.text('CHAIN'), findsOneWidget);
        expect(_chain1Runs, before.$1 + 1);
        expect(_chain2Runs, before.$2 + 1);
        _gate = null;
        // The second guard was evaluated in the continuation of the first, after the call of the
        // re-run: it belongs to the page all the same.
        c.read(_role.notifier).set(false);
        await _settle(tester);
        expect(find.text('CHAIN'), findsNothing);
        expect(find.text('LOGIN'), findsOneWidget);
      });

      testWidgets('a parent\'s synchronous guard and its child\'s asynchronous '
          'one each run once, and both are watched', (tester) async {
        final r = _router();
        final c = await pumpRouter(tester, attached(r));
        await _push(tester, r, '/p/c');
        await _push(tester, r, '/x');
        _gate = Completer<void>();
        final before = (_parentRuns, _childRuns);
        r.pop();
        await _settle(tester);
        _gate!.complete();
        await _settle(tester);
        expect(find.text('CHILD'), findsOneWidget);
        expect(_parentRuns, before.$1 + 1);
        expect(_childRuns, before.$2 + 1);
        _gate = null;
        c.read(_session.notifier).set(false);
        await _settle(tester);
        expect(find.text('LOGIN'), findsOneWidget);
        expect(_stack(r).last, '/login');
      });
    });
  });
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
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => count++),
    child: Text('COUNT $count'),
  );
}
