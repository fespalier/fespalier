// `leaveExit(within:)` (since 0.11.0): the steps of a flow share one `leave()`, asked once, when the
// navigation leaves the section. The routes are what the generator writes for a flow's steps.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final List<String> asked = [];
bool allow = true;

GoRoute step(String path, String label) => GoRoute(
  path: path,
  onExit: (context, state) =>
      leaveExit(context, state, 'f/leave.dart', (ref, page) {
        asked.add(label);
        return allow;
      }, within: '/f'),
  pageBuilder: (context, state) => MaterialPage<void>(
    key: state.pageKey,
    child: leaveScope(state, Scaffold(body: Text(label))),
  ),
);

GoRouter makeRouter() => GoRouter(
  initialLocation: '/f/one',
  routes: [
    step('/f/one', 'one'),
    step('/f/two', 'two'),
    GoRoute(
      path: '/home',
      pageBuilder: (context, state) => MaterialPage<void>(
        key: state.pageKey,
        child: const Scaffold(body: Text('home')),
      ),
    ),
    GoRoute(
      path: '/fx',
      pageBuilder: (context, state) => MaterialPage<void>(
        key: state.pageKey,
        child: const Scaffold(body: Text('fx')),
      ),
    ),
  ],
);

Future<GoRouter> boot(WidgetTester tester) async {
  final router = makeRouter();
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp.router(routerConfig: router)),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  setUp(() {
    asked.clear();
    allow = true;
  });

  testWidgets('go, replace and restore inside the section are not asked', (
    tester,
  ) async {
    final router = await boot(tester);
    router.go('/f/two');
    await tester.pumpAndSettle();
    expect(find.text('two'), findsOneWidget);
    unawaited(router.replace<void>('/f/one'));
    await tester.pumpAndSettle();
    expect(find.text('one'), findsOneWidget);
    expect(asked, isEmpty);
  });

  testWidgets('leaving the section asks, once, and a refusal keeps the page', (
    tester,
  ) async {
    final router = await boot(tester);
    allow = false;
    router.go('/home');
    await tester.pumpAndSettle();
    expect(asked, ['one']);
    expect(find.text('one'), findsOneWidget);
    allow = true;
    router.go('/home');
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a path that only starts like the section is outside it', (
    tester,
  ) async {
    final router = await boot(tester);
    router.go('/fx');
    await tester.pumpAndSettle();
    expect(asked, ['one']);
  });

  testWidgets('a pop that lands inside the section is not asked', (
    tester,
  ) async {
    final router = await boot(tester);
    unawaited(router.push<void>('/f/two'));
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('one'), findsOneWidget);
    expect(asked, isEmpty);
  });

  testWidgets('a pop that lands outside the section is asked', (tester) async {
    final router = await boot(tester);
    router.go('/home');
    await tester.pumpAndSettle();
    asked.clear();
    unawaited(router.push<void>('/f/two'));
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(asked, ['two']);
    asked.clear();
    unawaited(router.push<void>('/f/one'));
    await tester.pumpAndSettle();
    allow = false;
    router.pop();
    await tester.pumpAndSettle();
    expect(asked, ['one']);
    expect(find.text('one'), findsOneWidget);
  });
}
