// `TypedLocation.replace` and what the browser's address bar shows for it.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class ItemLoc extends TypedLocation {
  const ItemLoc(this.id);
  final int id;
  @override
  String get location => '/items/$id';
}

class NestedLoc extends TypedLocation {
  const NestedLoc(this.id);
  final int id;
  @override
  String get location => '/p/c/$id';
}

class InLoc extends TypedLocation {
  const InLoc(this.id);
  final int id;
  @override
  String get location => '/in/$id';
}

/// A page with state of its own: how often it was tapped.
class Counter extends StatefulWidget {
  const Counter({super.key, required this.label});
  final String label;
  @override
  State<Counter> createState() => _CounterState();
}

class _CounterState extends State<Counter> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('${widget.label} taps=$taps'),
  );
}

GoRouter makeRouter(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('Home')),
    GoRoute(
      path: '/items/:id',
      builder: (_, s) => Counter(label: 'Item ${s.pathParameters['id']}'),
    ),
    GoRoute(
      path: '/p',
      builder: (_, _) => const Text('P'),
      routes: [
        GoRoute(
          path: 'c/:id',
          builder: (_, s) => Counter(label: 'Nested ${s.pathParameters['id']}'),
        ),
      ],
    ),
    GoRoute(path: '/extra', builder: (_, s) => Text('extra=${s.extra}')),
    ShellRoute(
      builder: (_, _, child) => Column(
        children: [
          const Text('Shell'),
          Expanded(child: child),
        ],
      ),
      routes: [
        GoRoute(
          path: '/in/:id',
          builder: (_, s) => Counter(label: 'In ${s.pathParameters['id']}'),
        ),
      ],
    ),
  ],
);

/// What the app told the platform (the browser's history) about its location.
typedef HistoryUpdate = ({String uri, bool replace});

Future<(GoRouter, List<HistoryUpdate>)> boot(
  WidgetTester tester,
  String location,
) async {
  final history = <HistoryUpdate>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.navigation,
    (call) async {
      if (call.method == 'routeInformationUpdated') {
        final args = call.arguments as Map<Object?, Object?>;
        history.add((
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
  final router = makeRouter(location);
  await pumpRouter(tester, router);
  history.clear();
  return (router, history);
}

/// The address bar: what the router last handed to the platform.
String addressBar(GoRouter router) =>
    router.routeInformationProvider.value.uri.toString();

BuildContext top(WidgetTester tester) =>
    tester.element(find.byType(Counter).last);

void main() {
  final saved = GoRouter.optionURLReflectsImperativeAPIs;
  setUp(() => GoRouter.optionURLReflectsImperativeAPIs = false);
  tearDown(() => GoRouter.optionURLReflectsImperativeAPIs = saved);

  group('replace of a page of the declarative stack', () {
    testWidgets('shows the new location, replaces the history entry, '
        'and keeps the page state', (tester) async {
      final (router, history) = await boot(tester, '/items/1');
      await tester.tap(find.text('Item 1 taps=0'));
      await tester.pump();
      expect(find.text('Item 1 taps=1'), findsOneWidget);

      const ItemLoc(2).replace(top(tester));
      await tester.pumpAndSettle();

      expect(currentLocation(tester), '/items/2');
      expect(addressBar(router), '/items/2');
      expect(history, [(uri: '/items/2', replace: true)]);
      // The same page (go_router keys it by `/items/:id`): its state is kept.
      expect(find.text('Item 2 taps=1'), findsOneWidget);
    });

    testWidgets('twice is two replaced history entries, no new one', (
      tester,
    ) async {
      final (router, history) = await boot(tester, '/items/1');
      const ItemLoc(2).replace(top(tester));
      await tester.pumpAndSettle();
      const ItemLoc(3).replace(top(tester));
      await tester.pumpAndSettle();
      expect(addressBar(router), '/items/3');
      expect(history.map((h) => h.replace), [true, true]);
    });

    testWidgets('goes to another route, with its extra', (tester) async {
      final (router, history) = await boot(tester, '/items/1');
      replaceLocation(top(tester), '/extra', extra: 'hello');
      await tester.pumpAndSettle();
      expect(find.text('extra=hello'), findsOneWidget);
      expect(addressBar(router), '/extra');
      expect(history, [(uri: '/extra', replace: true)]);
    });

    testWidgets('of a page built over another one', (tester) async {
      // `/p/c/:id` is a child of `/p`, so the stack is two pages: go_router's own
      // `replace` would make the top an imperative match, which is not the `uri`.
      final (router, history) = await boot(tester, '/p/c/1');
      await tester.tap(find.text('Nested 1 taps=0'));
      await tester.pump();

      const NestedLoc(2).replace(top(tester));
      await tester.pumpAndSettle();

      expect(currentLocation(tester), '/p/c/2');
      expect(addressBar(router), '/p/c/2');
      expect(history, [(uri: '/p/c/2', replace: true)]);
      expect(find.text('Nested 2 taps=1'), findsOneWidget);
      expect(find.text('P', skipOffstage: false), findsOneWidget);
    });

    testWidgets('inside a shell it is the same', (tester) async {
      final (router, history) = await boot(tester, '/in/1');
      await tester.tap(find.text('In 1 taps=0'));
      await tester.pump();

      const InLoc(2).replace(top(tester));
      await tester.pumpAndSettle();

      expect(currentLocation(tester), '/in/2');
      expect(addressBar(router), '/in/2');
      expect(history, [(uri: '/in/2', replace: true)]);
      expect(find.text('In 2 taps=1'), findsOneWidget);
      expect(find.text('Shell'), findsOneWidget);
    });
  });

  group('replace of a pushed page', () {
    testWidgets('keeps the stack below it', (tester) async {
      final (router, _) = await boot(tester, '/');
      unawaited(const ItemLoc(1).push<void>(tester.element(find.text('Home'))));
      await tester.pumpAndSettle();
      expect(find.text('Item 1 taps=0'), findsOneWidget);

      const ItemLoc(2).replace(top(tester));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/2');
      expect(find.text('Item 2 taps=0'), findsOneWidget);
      expect(find.text('Item 1 taps=0'), findsNothing);
      // Home is still underneath: a `go` would have dropped it.
      expect(find.text('Home', skipOffstage: false), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(currentLocation(tester), '/');
    });

    testWidgets('keeps the stack below it, inside a shell', (tester) async {
      final (router, _) = await boot(tester, '/in/1');
      unawaited(const InLoc(2).push<void>(top(tester)));
      await tester.pumpAndSettle();
      expect(find.text('In 2 taps=0'), findsOneWidget);

      const InLoc(3).replace(top(tester));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/in/3');
      expect(find.text('In 3 taps=0'), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('In 1 taps=0'), findsOneWidget);
      expect(currentLocation(tester), '/in/1');
    });

    testWidgets('is not in the address bar unless go_router is told', (
      tester,
    ) async {
      final (router, _) = await boot(tester, '/');
      unawaited(const ItemLoc(1).push<void>(tester.element(find.text('Home'))));
      await tester.pumpAndSettle();
      const ItemLoc(2).replace(top(tester));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/2');
      expect(addressBar(router), '/');
    });

    testWidgets('is in the address bar when go_router reflects pushes', (
      tester,
    ) async {
      GoRouter.optionURLReflectsImperativeAPIs = true;
      final (router, _) = await boot(tester, '/');
      unawaited(const ItemLoc(1).push<void>(tester.element(find.text('Home'))));
      await tester.pumpAndSettle();
      expect(addressBar(router), '/items/1');

      const ItemLoc(2).replace(top(tester));
      await tester.pumpAndSettle();
      expect(addressBar(router), '/items/2');
      expect(find.text('Home', skipOffstage: false), findsOneWidget);
    });
  });

  group('push', () {
    testWidgets('keeps the address bar on the page below by default', (
      tester,
    ) async {
      final (router, history) = await boot(tester, '/');
      unawaited(const ItemLoc(1).push<void>(tester.element(find.text('Home'))));
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/items/1');
      expect(addressBar(router), '/');
      // The platform is told about the stack again, but still of `/`.
      expect(history.map((h) => h.uri).toSet(), everyElement('/'));
    });

    testWidgets('is in the address bar when go_router reflects it', (
      tester,
    ) async {
      GoRouter.optionURLReflectsImperativeAPIs = true;
      final (router, history) = await boot(tester, '/');
      unawaited(const ItemLoc(1).push<void>(tester.element(find.text('Home'))));
      await tester.pumpAndSettle();
      expect(addressBar(router), '/items/1');
      expect(history, [(uri: '/items/1', replace: false)]);

      router.pop();
      await tester.pumpAndSettle();
      expect(addressBar(router), '/');
    });
  });
}
