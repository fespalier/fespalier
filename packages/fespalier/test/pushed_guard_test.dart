// A guard on a pushed page holds after go_router's refresh (fespalier/fespalier#258). The two
// canaries are plain go_router, with no fespalier: they assert what go_router does today, and fail on
// purpose when a go_router release runs a pushed page's redirect on a refresh (then fespalier's
// handling is only a second check, and docs/guards.md's "what go_router still skips" must change).
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether a guard lets its page through, read through a provider nothing watches (a
/// `ProviderContainer` guard).
var allowed = true;
final allowedProvider = Provider.autoDispose<GuardResult>(
  (ref) => allowed ? null : '/home',
  retry: (_, _) => null,
);
GuardResult allowedGuard(ProviderContainer container) =>
    container.read(allowedProvider);

void main() {
  setUp(() {
    allowed = true;
  });

  group('go_router alone (canaries, fespalier/fespalier#258)', () {
    testWidgets(
      'canary: a refresh after a pushed redirect threw still shows the page',
      (tester) async {
        var redirectRuns = 0;
        final router = GoRouter(
          initialLocation: '/home',
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
            GoRoute(
              path: '/secret',
              redirect: (context, state) {
                redirectRuns++;
                throw StateError('the guard failed');
              },
              builder: (_, _) => const Text('SECRET'),
            ),
          ],
          errorBuilder: (_, state) => Text('ERROR ${state.error}'),
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        unawaited(router.push<void>('/secret'));
        await tester.pumpAndSettle();
        expect(redirectRuns, 1);
        expect(find.textContaining('ERROR'), findsOneWidget);
        router.refresh();
        await tester.pumpAndSettle();
        expect(
          redirectRuns,
          1,
          reason:
              'canary: go_router 18.1.x does not run a pushed redirect on refresh(). If this '
              'fails, go_router fixed flutter/flutter#133985 (or its error case): read '
              'docs/guards.md, "What go_router still skips", and fespalier/fespalier#258 before '
              'changing anything.',
        );
        expect(
          find.text('SECRET'),
          findsOneWidget,
          reason:
              'canary: the guarded page shows after refresh(), as in fespalier/fespalier#258',
        );
      },
    );

    testWidgets(
      'canary: a refresh after a pushed page whose redirect now refuses keeps it',
      (tester) async {
        var allow = true;
        var redirectRuns = 0;
        final router = GoRouter(
          initialLocation: '/home',
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
            GoRoute(
              path: '/secret',
              redirect: (context, state) {
                redirectRuns++;
                return allow ? null : '/home';
              },
              builder: (_, _) => const Text('SECRET'),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        unawaited(router.push<void>('/secret'));
        await tester.pumpAndSettle();
        expect(find.text('SECRET'), findsOneWidget);
        allow = false;
        router.refresh();
        await tester.pumpAndSettle();
        expect(
          redirectRuns,
          1,
          reason:
              'canary: go_router 18.1.x does not run a pushed redirect on refresh(). If this '
              'fails, go_router fixed it: see the canary above.',
        );
        expect(
          find.text('SECRET'),
          findsOneWidget,
          reason:
              'canary: the pushed page stays after refresh(), as in fespalier/fespalier#258',
        );
      },
    );
  });

  group('fespalier holds a guard on a pushed page after a refresh', () {
    GoRouter router() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(
          path: '/secret',
          redirect: (context, state) => runRedirect(
            () =>
                allowedGuard(ProviderScope.containerOf(context, listen: false)),
          ),
          builder: (_, _) => const Text('SECRET'),
        ),
      ],
    );

    testWidgets(
      'a ProviderContainer guard that now refuses moves the pushed page on refresh',
      (tester) async {
        final r = router();
        await pumpRouter(tester, r);
        unawaited(r.push<void>('/secret'));
        await tester.pumpAndSettle();
        expect(find.text('SECRET'), findsOneWidget);
        allowed = false;
        r.refresh();
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/home');
        expect(find.text('SECRET'), findsNothing);
      },
    );

    testWidgets(
      'a refresh after a pushed page whose guard passes keeps the page',
      (tester) async {
        final r = router();
        await pumpRouter(tester, r);
        unawaited(r.push<void>('/secret'));
        await tester.pumpAndSettle();
        r.refresh();
        await tester.pumpAndSettle();
        expect(find.text('SECRET'), findsOneWidget);
      },
    );
  });

  group('the gate of a page holds the entry by its page key', () {
    /// How often a counter page was built from scratch, and how often the guard ran.
    var states = 0;
    var runs = 0;

    GoRouter gated() => GoRouter(
      initialLocation: '/checkout',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(
          path: '/checkout',
          redirect: (context, state) => runRedirect(() {
            runs++;
            // The second run is the push, which fails; every other run passes.
            if (runs == 2) throw StateError('boom');
            return null;
          }),
          // The generated page builder of a guarded route.
          builder: (context, state) =>
              refusedView(context, state) ?? _Counter(onState: () => states++),
        ),
      ],
      errorBuilder: (context, state) => routerErrorPage(
        context,
        state,
        (uri) => Text('NOT FOUND ${uri.path}'),
        guardError: (uri, error, stackTrace, retry) => const Text('ERROR'),
      ),
    );

    setUp(() {
      states = 0;
      runs = 0;
    });

    testWidgets('a base page at the same location as a held page keeps its state', (
      tester,
    ) async {
      final r = gated();
      await pumpRouter(tester, r);
      expect(states, 1);
      await tester.tap(find.text('COUNT 0'));
      await tester.pump();
      expect(find.text('COUNT 1'), findsOneWidget);
      // The push fails: its entry is the error view, over a base page that passed.
      unawaited(r.push<void>('/checkout'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('ERROR'), findsOneWidget);
      // A refresh restores both without their redirects. The entry that never passed is held,
      // and the base page, which has the same location, is not.
      r.refresh();
      await tester.pump();
      expect(
        find.text('COUNT 1', skipOffstage: false),
        findsOneWidget,
        reason:
            'the base page is built, with its state, while the entry is held',
      );
      await tester.pumpAndSettle();
      // The refresh ran the guard of the base page (the third run) and the entry's guard ran again
      // and passed (the fourth): its page is a second counter, and the base page under it is the
      // one it was, never built again.
      expect(runs, 4);
      expect(states, 2);
      expect(find.text('COUNT 1', skipOffstage: false), findsOneWidget);
      expect(find.text('COUNT 0'), findsOneWidget);
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
