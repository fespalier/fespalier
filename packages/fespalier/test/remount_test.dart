// A page keeps its state when only its parameters change (go_router keys it by its path
// template); `remountKey` and `remountPage` are what the generated router uses to give it a
// fresh one: on a segment's value (`onSegments`), or on any change of the location
// (`onLocation`). The routers here are what the generator writes for a route with and
// without a transition.dart.
import 'dart:async' show unawaited;

import 'package:fespalier/fespalier.dart';
import 'package:flutter/cupertino.dart' show CupertinoApp, CupertinoPage;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// How often a page's state was created.
var created = 0;

class Counter extends StatefulWidget {
  const Counter(this.label, {super.key});

  final String label;

  @override
  State<Counter> createState() => _CounterState();
}

class _CounterState extends State<Counter> {
  var taps = 0;

  @override
  void initState() {
    super.initState();
    created++;
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('${widget.label} taps $taps'),
  );
}

enum Style {
  /// `builder:` in the generated code, so `remountPage` builds the page.
  builder,

  /// `pageBuilder:` with a transition.dart that takes the key.
  transition,
}

GoRouter router(Remount remount, Style style, {String initial = '/x/1'}) {
  Widget page(GoRouterState state) => Counter(state.pathParameters['id']!);
  return GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/x/:id',
        pageBuilder: (context, state) => switch (style) {
          Style.transition => Transitions.none(
            remountKey(state, remount, const ['id']),
            page(state),
          ),
          Style.builder => remountPage(
            context,
            state,
            remountKey(state, remount, const ['id']),
            page(state),
          ),
        },
        routes: [
          GoRoute(
            path: 'edit',
            builder: (context, state) => const Text('edit'),
          ),
        ],
      ),
    ],
  );
}

Future<GoRouter> boot(WidgetTester tester, Remount remount, Style style) async {
  final r = router(remount, style);
  addTearDown(r.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: r));
  await tester.pumpAndSettle();
  return r;
}

Future<void> go(WidgetTester tester, GoRouter r, String location) async {
  r.go(location);
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester) async {
  await tester.tap(find.byType(TextButton));
  await tester.pump();
}

void main() {
  setUp(() => created = 0);

  for (final style in Style.values) {
    group(style.name, () {
      testWidgets('never keeps the state when a segment changes', (
        tester,
      ) async {
        final r = await boot(tester, Remount.never, style);
        await tap(tester);
        expect(find.text('1 taps 1'), findsOneWidget);
        await go(tester, r, '/x/2');
        expect(find.text('2 taps 1'), findsOneWidget);
        expect(created, 1);
      });

      testWidgets('onSegments starts again when a segment changes', (
        tester,
      ) async {
        final r = await boot(tester, Remount.onSegments, style);
        await tap(tester);
        await go(tester, r, '/x/2');
        expect(find.text('2 taps 0'), findsOneWidget);
        expect(created, 2);
      });

      testWidgets('onSegments keeps the state when the query changes', (
        tester,
      ) async {
        final r = await boot(tester, Remount.onSegments, style);
        await tap(tester);
        await go(tester, r, '/x/1?page=2');
        await go(tester, r, '/x/1?page=3&tags=a');
        expect(find.text('1 taps 1'), findsOneWidget);
        expect(created, 1);
      });

      testWidgets('onLocation starts again on a segment and on a query', (
        tester,
      ) async {
        final r = await boot(tester, Remount.onLocation, style);
        await tap(tester);
        await go(tester, r, '/x/1?page=2');
        expect(find.text('1 taps 0'), findsOneWidget);
        expect(created, 2);
        await tap(tester);
        await go(tester, r, '/x/2?page=2');
        expect(find.text('2 taps 0'), findsOneWidget);
        expect(created, 3);
      });

      testWidgets('onLocation keeps the state with the same location', (
        tester,
      ) async {
        final r = await boot(tester, Remount.onLocation, style);
        await tap(tester);
        await go(tester, r, '/x/1');
        expect(find.text('1 taps 1'), findsOneWidget);
        expect(created, 1);
      });

      testWidgets('a page below it does not start the one under it again', (
        tester,
      ) async {
        for (final remount in [Remount.onSegments, Remount.onLocation]) {
          created = 0;
          final r = router(remount, style);
          addTearDown(r.dispose);
          await tester.pumpWidget(MaterialApp.router(routerConfig: r));
          await tester.pumpAndSettle();
          await tap(tester);
          unawaited(r.push('/x/1/edit'));
          await tester.pumpAndSettle();
          expect(find.text('edit'), findsOneWidget);
          r.pop();
          await tester.pumpAndSettle();
          expect(find.text('1 taps 1'), findsOneWidget, reason: '$remount');
          expect(created, 1, reason: '$remount');
        }
      });
    });
  }

  group('remountKey', () {
    GoRouterState stateOf(WidgetTester tester) =>
        GoRouterState.of(tester.element(find.byType(Counter)));

    testWidgets('is go_router\'s own key for never', (tester) async {
      await boot(tester, Remount.never, Style.builder);
      final state = stateOf(tester);
      expect(remountKey(state, Remount.never), state.pageKey);
    });

    testWidgets('names the segments for onSegments, not the query', (
      tester,
    ) async {
      final r = await boot(tester, Remount.never, Style.builder);
      await go(tester, r, '/x/a%20b?q=1');
      final state = stateOf(tester);
      expect(
        remountKey(state, Remount.onSegments, const ['id']).value,
        '/x/:id#a%20b',
      );
      expect(remountKey(state, Remount.onSegments).value, '/x/:id#');
    });

    testWidgets('is the matched location and the query for onLocation', (
      tester,
    ) async {
      final r = await boot(tester, Remount.never, Style.builder);
      await go(tester, r, '/x/7?q=1#top');
      expect(
        remountKey(stateOf(tester), Remount.onLocation).value,
        '/x/:id#/x/7?q=1',
      );
    });
  });

  testWidgets('remountPage is a Cupertino page in a CupertinoApp', (
    tester,
  ) async {
    Page<void>? built;
    final r = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) => built = remountPage(
            context,
            state,
            remountKey(state, Remount.onLocation),
            const Text('home'),
          ),
        ),
      ],
    );
    addTearDown(r.dispose);
    await tester.pumpWidget(CupertinoApp.router(routerConfig: r));
    expect(built, isA<CupertinoPage<void>>());
    expect(built?.key, const ValueKey<String>('/#/?'));
    expect(built?.restorationId, '/#/?');
  });
}
