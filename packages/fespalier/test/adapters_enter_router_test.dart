// go_router's `onEnter` is passed only when an adapter has an `onEnter` getter (since 0.16.0). The routers here
// are built the way the generated `AppRoutes.router` builds its own:
// `onEnter: all.handlesEnter ? all.onEnter : null`. Any `onEnter` makes go_router parse every
// navigation asynchronously, so an app whose adapters leave it alone must keep the synchronous
// parse: `go()` commits in the call, and `go()` then `push()` keeps both. No timer.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart'
    show FespalierAdapter, FespalierAdapters;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Overrides nothing: every member is the default.
class _Default extends FespalierAdapter {
  const _Default();
}

/// Handles `onEnter`, and writes down what it is asked.
class _Handler extends FespalierAdapter {
  _Handler(this.seen);

  final List<String> seen;

  @override
  FespalierEnter? get onEnter => (navigation) {
    seen.add(
      '${navigation.next.uri.path}${navigation.initial ? ' (initial)' : ''}',
    );
    if (navigation.next.uri.path != '/custom') return null;
    return Block.then(() => navigation.router.go('/b'));
  };
}

Widget _page(String label) => Scaffold(body: Text(label));

/// A router the way the generated code builds it.
GoRouter _router(List<FespalierAdapter> adapters) {
  final all = FespalierAdapters(adapters);
  return GoRouter(
    initialLocation: '/home',
    onEnter: all.handlesEnter ? all.onEnter : null,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => _page('home')),
      GoRoute(path: '/a', builder: (_, _) => _page('a')),
      GoRoute(path: '/b', builder: (_, _) => _page('b')),
      GoRoute(path: '/custom', builder: (_, _) => _page('custom')),
    ],
  );
}

/// The router's stack, bottom first: a matched location, or a pushed page's.
List<String> _stack(GoRouter router) => [
  for (final match in router.routerDelegate.currentConfiguration.matches)
    match is ImperativeRouteMatch
        ? match.matches.uri.path
        : match.matchedLocation,
];

Future<GoRouter> _pump(WidgetTester tester, GoRouter router) async {
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('adapters that leave onEnter alone', () {
    testWidgets('go_router gets no onEnter', (tester) async {
      final router = await _pump(
        tester,
        _router(const [_Default(), _Default()]),
      );
      expect(router.configuration.topOnEnter, isNull);
    });

    testWidgets('go() commits in the call, with no pump', (tester) async {
      final router = await _pump(tester, _router(const [_Default()]));
      router.go('/a');
      expect(router.routerDelegate.currentConfiguration.uri.path, '/a');
    });

    testWidgets('go() then push() keeps both', (tester) async {
      final router = await _pump(tester, _router(const [_Default()]));
      router.go('/a');
      unawaited(router.push('/b'));
      await tester.pumpAndSettle();
      expect(_stack(router), ['/a', '/b']);
    });
  });

  group('an adapter that handles onEnter', () {
    testWidgets('go_router gets onEnter, and the adapter is asked for each '
        'navigation, the first included', (tester) async {
      final seen = <String>[];
      final router = await _pump(
        tester,
        _router([const _Default(), _Handler(seen)]),
      );
      expect(router.configuration.topOnEnter, isNotNull);
      expect(seen, ['/home (initial)']);
      router.go('/a');
      await tester.pumpAndSettle();
      expect(seen, ['/home (initial)', '/a']);
      expect(_stack(router), ['/a']);
    });

    testWidgets('its Block.then rewrites a navigation', (tester) async {
      final seen = <String>[];
      final router = await _pump(tester, _router([_Handler(seen)]));
      router.go('/custom');
      await tester.pumpAndSettle();
      expect(_stack(router), ['/b']);
      expect(seen, containsAllInOrder(['/custom', '/b']));
    });

    testWidgets('the parse is asynchronous: the documented cost', (
      tester,
    ) async {
      final router = await _pump(tester, _router([_Handler(<String>[])]));
      router.go('/a');
      // Not committed in the call: go_router parses through onEnter's Future.
      expect(router.routerDelegate.currentConfiguration.uri.path, '/home');
      await tester.pumpAndSettle();
      expect(router.routerDelegate.currentConfiguration.uri.path, '/a');
    });
  });
}
