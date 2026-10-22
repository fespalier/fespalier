// What a guard's re-run of a pushed page asks `leave()` when the router has an `onEnter` (a limit of
// the re-run, docs/guards.md "What go_router still skips, and the limits of a re-run", number 3):
// go_router waits for any `onEnter`, a synchronous one too, before it parses, so the redirects of the
// re-run run after its `replace` call has returned and the landing has no verdict from its guards.
// Without an `onEnter` a re-run whose guard passes again asks nothing.
//
// The probe B of the review of #268, kept as a test, in every order the lifecycle watch can listen in.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';

/// What each `leave()` was asked.
final _asked = <String>[];

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

/// A page with unsaved changes.
class _Source extends ChangeNotifier implements LeaveSource {
  @override
  bool get isDirty => true;

  @override
  bool get canKeep => false;

  @override
  FutureOr<void> keep() {}

  @override
  void discard() {}
}

/// Registers a dirty [_Source] with the page's `LeaveScope`.
class _Dirty extends StatefulWidget {
  const _Dirty({required this.child});

  final Widget child;

  @override
  State<_Dirty> createState() => _DirtyState();
}

class _DirtyState extends State<_Dirty> {
  VoidCallback? _unregister;

  @override
  void initState() {
    super.initState();
    _unregister = LeaveScope.maybeOf(context)?.register(_Source());
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

GoRouter _router({OnEnter? onEnter}) => GoRouter(
  initialLocation: '/home',
  onEnter: onEnter,
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
    GoRoute(
      path: '/x',
      builder: (_, _) => Scaffold(appBar: AppBar(), body: const Text('PAGE X')),
    ),
    // A dirty page with a guard that passes.
    GoRoute(
      path: '/d',
      redirect: (context, state) =>
          runRedirect(state, () => refGuard(context, 'g@d', (ref) => null)),
      onExit: (context, state) =>
          leaveExit(context, state, 'd/leave.dart', (ref, page) {
            _asked.add(page.isDirty ? 'd dirty' : 'd');
            return true;
          }),
      pageBuilder: (context, state) => MaterialPage<void>(
        key: state.pageKey,
        child: leaveScope(
          state,
          refusedView(context, state) ??
              _Dirty(
                child: Scaffold(appBar: AppBar(), body: const Text('D')),
              ),
        ),
      ),
    ),
  ],
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  setUp(_asked.clear);

  inEveryOrder(() {
    // The page is covered and uncovered, which runs its guard again; the guard passes.
    Future<GoRouter> uncovered(WidgetTester tester, {OnEnter? onEnter}) async {
      final r = _router(onEnter: onEnter);
      await pumpRouter(tester, attached(r));
      unawaited(r.push<void>('/d'));
      await _settle(tester);
      unawaited(r.push<void>('/x'));
      await _settle(tester);
      _asked.clear();
      r.pop();
      await _settle(tester);
      return r;
    }

    testWidgets('no onEnter: a re-run that passes again asks nothing', (
      tester,
    ) async {
      final r = await uncovered(tester);
      expect(_stack(r), ['/home', '/d']);
      expect(_asked, isEmpty);
    });

    testWidgets('a synchronous onEnter: the same re-run asks the dirty page', (
      tester,
    ) async {
      final r = await uncovered(
        tester,
        onEnter: (c, from, to, r) => const Allow(),
      );
      expect(_stack(r), ['/home', '/d']);
      expect(_asked, ['d dirty'], reason: 'the verdict of the guards is lost');
    });

    testWidgets('an asynchronous onEnter: the same', (tester) async {
      final r = await uncovered(
        tester,
        onEnter: (c, from, to, r) async => const Allow(),
      );
      expect(_stack(r), ['/home', '/d']);
      expect(_asked, ['d dirty']);
    });
  });
}
