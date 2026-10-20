// A guard that fails (since 0.21.0): what go_router gets, what the error route shows, the one
// debug report and the retry. The zone tests stand in for go_router 17.2.3 to 18.1.0, which ran a
// redirect in an error zone of their own; the widget tests run on every go_router.
import 'dart:async';
import 'dart:io';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// go_router's zone value for the router (`currentRouterKey`).
const routerKey = #goRouterRedirectContext;

/// How many microtasks and timers [body] schedules in its own zone (each is passed on to the parent).
({int microtasks, int timers}) countAsync(void Function() body) {
  var microtasks = 0;
  var timers = 0;
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, f) {
        microtasks++;
        parent.scheduleMicrotask(zone, f);
      },
      createTimer: (self, parent, zone, d, f) {
        timers++;
        return parent.createTimer(zone, d, f);
      },
      createPeriodicTimer: (self, parent, zone, d, f) {
        timers++;
        return parent.createPeriodicTimer(zone, d, f);
      },
    ),
  );
  return (microtasks: microtasks, timers: timers);
}

/// What the guard of `/inbox` answers, and how often it ran.
var inboxRuns = 0;
GuardResult Function(Ref ref) inbox = (ref) => null;

/// What the `/plain` guard answers: a `ProviderContainer` guard, called with the app's container.
GuardResult Function() plainAnswer = () => null;
final plainProvider = Provider<GuardResult>(
  (ref) => plainAnswer(),
  retry: (_, _) => null,
);
GuardResult plainGuard(ProviderContainer container) =>
    container.read(plainProvider);

/// The retry of the last view built, and the state of the last error page built.
VoidCallback? heldRetry;
GoRouterState? lastErrorState;

/// The view a failed guard of `/inbox` and `/plain` shows: its error, and a button that retries.
final class GuardErrorView extends StatelessWidget {
  const GuardErrorView({required this.error, required this.retry, super.key});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: retry, child: Text('ERROR $error'));
}

Widget? _view(
  Uri uri,
  Object error,
  StackTrace stackTrace,
  VoidCallback retry,
) {
  if (uri.path != '/inbox' && uri.path != '/plain') return null;
  heldRetry = retry;
  return GuardErrorView(error: error, retry: retry);
}

GoRouter router({String initial = '/other', bool withView = true}) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(path: '/other', builder: (_, _) => const Text('OTHER')),
    GoRoute(path: '/under', builder: (_, _) => const Text('UNDER')),
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => shell,
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/t1', builder: (_, _) => const Text('T1'))],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/t2', builder: (_, _) => const Text('T2'))],
        ),
      ],
    ),
    GoRoute(
      path: '/inbox',
      redirect: (context, state) => runRedirect(
        () => traceGuard(
          state,
          'g1@1',
          refGuard(context, 'g1@1', (ref) {
            inboxRuns++;
            return inbox(ref);
          }),
        ),
      ),
      builder: (_, state) => Text(
        'INBOX${state.extra == null ? '' : ' ${state.uri.query} ${state.extra}'}',
      ),
    ),
    GoRoute(
      path: '/plain',
      redirect: (context, state) => runRedirect(
        () => plainGuard(ProviderScope.containerOf(context, listen: false)),
      ),
      builder: (_, _) => const Text('PLAIN'),
    ),
  ],
  errorBuilder: (context, state) {
    lastErrorState = state;
    return routerErrorPage(
      context,
      state,
      (uri) => Text('NOT FOUND ${uri.path}'),
      guardError: withView ? _view : null,
    );
  },
);

void main() {
  setUp(() {
    inboxRuns = 0;
    inbox = (ref) => null;
    plainAnswer = () => null;
    heldRetry = null;
    lastErrorState = null;
  });

  group('runRedirect', () {
    test('a sync answer is the very object, and schedules nothing', () {
      const location = '/login';
      late FutureOr<String?> result;
      final counts = countAsync(() {
        result = runRedirect(() => location);
      });
      expect(result, same(location));
      expect(counts.microtasks, 0);
      expect(counts.timers, 0);
    });

    test('a sync throw is a GuardFailure with what it threw and its stack', () {
      final stack = StackTrace.fromString('the guard');
      expect(
        () => runRedirect(
          () => Error.throwWithStackTrace(StateError('boom'), stack),
        ),
        throwsA(
          isA<GuardFailure>()
              .having((f) => f.error, 'error', isA<StateError>())
              .having((f) => f.stackTrace, 'stackTrace', same(stack)),
        ),
      );
    });

    test('a Riverpod ProviderException is taken off', () {
      final container = ProviderContainer(retry: (_, _) => null);
      addTearDown(container.dispose);
      final provider = Provider<String?>((ref) => throw StateError('boom'));
      expect(
        () => runRedirect(() => container.read(provider)),
        throwsA(
          isA<GuardFailure>().having(
            (f) => f.error,
            'error',
            isA<StateError>(),
          ),
        ),
      );
    });

    test('a GuardFailure is passed on as the same object', () {
      final failure = GuardFailure(StateError('boom'), StackTrace.empty);
      expect(() => runRedirect(() => throw failure), throwsA(same(failure)));
    });

    test('an async answer is a Future of its own, with the same value, and '
        'no timer', () async {
      final answer = Future<String?>.value('/login');
      late FutureOr<String?> result;
      final counts = countAsync(() {
        result = runRedirect(() => answer);
      });
      expect(result, isA<Future<String?>>());
      expect(identical(result, answer), isFalse);
      expect(counts.timers, 0);
      expect(await result, '/login');
    });

    test('an async failure is a GuardFailure with the error and the stack it '
        'failed with', () async {
      final stack = StackTrace.fromString('the guard');
      final answer = Future<String?>.error(StateError('boom'), stack);
      final result = runRedirect(() => answer) as Future<String?>;
      await expectLater(
        result,
        throwsA(
          isA<GuardFailure>()
              .having((f) => f.error, 'error', isA<StateError>())
              .having((f) => f.stackTrace, 'stackTrace', same(stack)),
        ),
      );
    });

    test('in the error zone go_router 17.2.3 to 18.1.0 ran a redirect in, the '
        'redirect runs in a fork of the caller, and its failure reaches the '
        'caller', () async {
      final outer = Zone.current;
      final router = Object();
      final guardErrors = <Object>[];
      late Zone inside;
      final seen = <Object?>[];
      final results = <FutureOr<String?>>[];
      runZonedGuarded(
        () {
          results.add(
            runRedirect(() {
              inside = Zone.current;
              seen.add(Zone.current[routerKey]);
              return Future<String?>.error(StateError('boom'));
            }),
          );
        },
        (error, _) => guardErrors.add(error),
        zoneValues: {routerKey: router},
      );
      expect(inside.inSameErrorZone(outer), isTrue);
      expect(seen, [same(router)]);
      await expectLater(results.single, throwsA(isA<GuardFailure>()));
      expect(guardErrors, isEmpty);
    });

    test('in an error zone of the app, with no router key, the redirect runs '
        'where it is', () {
      late Zone app;
      late Zone inside;
      runZonedGuarded(() {
        app = Zone.current;
        runRedirect(() {
          inside = Zone.current;
          return '/x';
        });
      }, (_, _) {});
      expect(inside, same(app));
    });

    test(
      'in the fork go_router 18.1.1 makes, the redirect runs there: no hop',
      () {
        final fork = Zone.current.fork(zoneValues: {routerKey: Object()});
        late Zone inside;
        fork.run(() {
          runRedirect(() {
            inside = Zone.current;
            return '/x';
          });
        });
        expect(inside, same(fork));
      },
    );
  });

  group('a guard that fails in a router', () {
    testWidgets('an async guard that fails: nothing is uncaught, and the error '
        'route shows it', (tester) async {
      inbox = (ref) async => throw StateError('boom');
      final r = router();
      await pumpRouter(tester, r);
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        r.go('/inbox');
        await tester.pumpAndSettle();
      }, (error, _) => uncaught.add(error));
      expect(uncaught, isEmpty);
      expect(r.routerDelegate.currentConfiguration.error, isA<GuardFailure>());
      expect(r.routerDelegate.currentConfiguration.uri.path, '/inbox');
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      expect(find.text('OTHER'), findsNothing);
      expect(tester.takeException(), isA<StateError>());
    });

    testWidgets('a sync guard that throws through refGuard: the same', (
      tester,
    ) async {
      inbox = (ref) => throw StateError('boom');
      final r = router();
      await pumpRouter(tester, r);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(r.routerDelegate.currentConfiguration.error, isA<GuardFailure>());
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      expect(find.text('OTHER'), findsNothing);
      expect(tester.takeException(), isA<StateError>());
    });

    testWidgets('a guard that reads a ProviderContainer directly: the same', (
      tester,
    ) async {
      plainAnswer = () => throw StateError('boom');
      final r = router();
      await pumpRouter(tester, r);
      r.go('/plain');
      await tester.pumpAndSettle();
      expect(r.routerDelegate.currentConfiguration.error, isA<GuardFailure>());
      expect(r.routerDelegate.currentConfiguration.uri.path, '/plain');
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      expect(find.text('OTHER'), findsNothing);
      expect(tester.takeException(), isA<StateError>());
    });

    testWidgets('without a view, the not-found view shows, and the failure is '
        'still reported', (tester) async {
      inbox = (ref) => throw StateError('boom');
      final r = router(withView: false);
      await pumpRouter(tester, r);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(find.text('NOT FOUND /inbox'), findsOneWidget);
      expect(tester.takeException(), isA<StateError>());
    });

    test('the report does not depend on the build mode', () {
      // `kDebugMode` is a constant, so no test can build in release: the report is in every build
      // mode as long as the file that makes it names no build mode. SentryFlutter.init hears it
      // through FlutterError.onError there.
      final source = File('lib/src/guards.dart').readAsStringSync();
      expect(source, isNot(contains('kDebugMode')));
      expect(source, isNot(contains('kReleaseMode')));
      expect(source, isNot(contains('assert(')));
    });

    testWidgets('the report is one FlutterErrorDetails, and a second build of '
        'the error page does not repeat it', (tester) async {
      inbox = (ref) => throw StateError('boom');
      final r = router();
      await pumpRouter(tester, r);
      final reports = <FlutterErrorDetails>[];
      final original = FlutterError.onError;
      FlutterError.onError = reports.add;
      try {
        r.go('/inbox');
        await tester.pumpAndSettle();
      } finally {
        FlutterError.onError = original;
      }
      expect(reports, hasLength(1));
      final report = reports.single;
      expect(report.library, 'fespalier');
      expect(
        report.context.toString(),
        contains('while running a guard or redirect.dart'),
      );
      expect(report.exception, isA<StateError>());
      expect(report.stack.toString(), contains('guard_failure_test.dart'));

      final element = tester.element(find.text('ERROR Bad state: boom'));
      FlutterError.onError = reports.add;
      try {
        routerErrorPage(element, lastErrorState!, (_) => const SizedBox());
      } finally {
        FlutterError.onError = original;
      }
      expect(reports, hasLength(1));
    });

    testWidgets(
      'the retry runs the guard again, and a success shows the page',
      (tester) async {
        var failFirst = true;
        inbox = (ref) {
          if (failFirst) {
            failFirst = false;
            throw StateError('boom');
          }
          return null;
        };
        final r = router();
        await pumpRouter(tester, r);
        r.go('/inbox');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isA<StateError>());
        await tester.tap(find.text('ERROR Bad state: boom'));
        await tester.pumpAndSettle();
        expect(find.text('INBOX'), findsOneWidget);
        expect(r.routerDelegate.currentConfiguration.error, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a retry held after the router moved on does nothing', (
      tester,
    ) async {
      inbox = (ref) => throw StateError('boom');
      final r = router();
      await pumpRouter(tester, r);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      final held = heldRetry!;
      r.go('/other');
      await tester.pumpAndSettle();
      final runsBefore = inboxRuns;
      held();
      await tester.pumpAndSettle();
      expect(inboxRuns, runsBefore);
      expect(find.text('OTHER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a location that matches no route shows the not-found view, '
        'with no report', (tester) async {
      final r = router();
      await pumpRouter(tester, r);
      r.go('/nowhere');
      await tester.pumpAndSettle();
      expect(find.text('NOT FOUND /nowhere'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the page a failed navigation leaves gets its onLeave', (
      tester,
    ) async {
      inbox = (ref) => throw StateError('boom');
      final r = router();
      final leaves = <String>[];
      observeAttach(
        r,
        (uri) => [
          if (uri.path == '/other')
            RouteHooks('observe.dart', onLeave: (_) => leaves.add('/other')),
        ],
      );
      await pumpRouter(tester, r);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(leaves, ['/other']);
      expect(tester.takeException(), isA<StateError>());
    });
  });
  // go_router keeps a navigation that failed its guard in an entry on top of the stack when it was
  // pushed (`push`, and `pushReplacement` and `replace` over other pages): the router's own `error`
  // stays null, and the failed list is the entry's `matches`.
  group('a guard that fails on a pushed navigation', () {
    Future<Object?> navigate(
      GoRouter r,
      String kind,
      String location, {
      Object? extra,
    }) => switch (kind) {
      'push' => r.push<Object?>(location, extra: extra),
      'pushReplacement' => r.pushReplacement<Object?>(location, extra: extra),
      _ => r.replace<Object?>(location, extra: extra),
    };

    /// The router with `/under` and, pushed over it, `/other`; [kind] then goes to `/inbox` with a
    /// query and an extra.
    Future<({GoRouter router, Future<Object?> answer, List<Object?> done})>
    fail(WidgetTester tester, String kind) async {
      final r = router(initial: '/under');
      await pumpRouter(tester, r);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      final done = <Object?>[];
      final answer = navigate(r, kind, '/inbox?x=1', extra: 'EX');
      unawaited(answer.then(done.add));
      await tester.pumpAndSettle();
      return (router: r, answer: answer, done: done);
    }

    for (final kind in ['push', 'pushReplacement', 'replace']) {
      testWidgets('$kind: the error view shows over the stack, the failure is '
          'reported once', (tester) async {
        inbox = (ref) => throw StateError('boom');
        final (:router, :answer, :done) = await fail(tester, kind);
        expect(inboxRuns, 1);
        expect(find.text('ERROR Bad state: boom'), findsOneWidget);
        expect(find.text('INBOX'), findsNothing);
        // `push` keeps the page it started from under the error view; the other two removed it.
        expect(
          find.text('OTHER', skipOffstage: false),
          kind == 'push' ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isA<StateError>());
        expect(tester.takeException(), isNull);
        expect(done, isEmpty);
      });

      testWidgets('$kind: the retry runs the guard again and shows the page '
          'once it passes', (tester) async {
        var failFirst = true;
        inbox = (ref) {
          if (failFirst) {
            failFirst = false;
            throw StateError('boom');
          }
          return null;
        };
        final (:router, :answer, :done) = await fail(tester, kind);
        expect(tester.takeException(), isA<StateError>());
        await tester.tap(find.text('ERROR Bad state: boom'));
        await tester.pumpAndSettle();
        expect(inboxRuns, 2);
        // The same location, query and extra as the navigation that failed.
        expect(find.text('INBOX x=1 EX'), findsOneWidget);
        expect(find.textContaining('ERROR'), findsNothing);
        expect(tester.takeException(), isNull);
        // The Future of the navigation that failed completes with null when its error view closes.
        expect(done, [null]);
        // The stack below is what it was: back to the page under the new one.
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text(kind == 'push' ? 'OTHER' : 'UNDER'), findsOneWidget);
      });

      testWidgets('$kind: a retry that fails again shows the error view again, '
          'and reports it', (tester) async {
        inbox = (ref) => throw StateError('boom');
        final (:router, :answer, :done) = await fail(tester, kind);
        expect(tester.takeException(), isA<StateError>());
        await tester.tap(find.text('ERROR Bad state: boom'));
        await tester.pumpAndSettle();
        expect(inboxRuns, 2);
        expect(find.text('ERROR Bad state: boom'), findsOneWidget);
        expect(tester.takeException(), isA<StateError>());
        expect(done, [null]);
      });

      testWidgets('$kind: a retry held after the error view closed does '
          'nothing', (tester) async {
        inbox = (ref) => throw StateError('boom');
        final (:router, :answer, :done) = await fail(tester, kind);
        expect(tester.takeException(), isA<StateError>());
        final held = heldRetry!;
        router.pop();
        await tester.pumpAndSettle();
        expect(done, [null]);
        final runs = inboxRuns;
        held();
        await tester.pumpAndSettle();
        expect(inboxRuns, runs);
        expect(find.text(kind == 'push' ? 'OTHER' : 'UNDER'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a retry held while another page is pushed over the error view '
        'does nothing', (tester) async {
      inbox = (ref) => throw StateError('boom');
      final (:router, :answer, :done) = await fail(tester, 'push');
      expect(tester.takeException(), isA<StateError>());
      final held = heldRetry!;
      unawaited(router.push<void>('/under'));
      await tester.pumpAndSettle();
      final runs = inboxRuns;
      held();
      await tester.pumpAndSettle();
      expect(inboxRuns, runs);
      expect(find.text('UNDER'), findsOneWidget);
      expect(done, isEmpty);
    });

    testWidgets('a push from a tab: the retry works the same', (tester) async {
      var failFirst = true;
      inbox = (ref) {
        if (failFirst) {
          failFirst = false;
          throw StateError('boom');
        }
        return null;
      };
      final r = router(initial: '/t2');
      await pumpRouter(tester, r);
      final answer = r.push<Object?>('/inbox');
      var done = false;
      unawaited(answer.whenComplete(() => done = true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      await tester.tap(find.text('ERROR Bad state: boom'));
      await tester.pumpAndSettle();
      expect(find.text('INBOX'), findsOneWidget);
      expect(done, isTrue);
      r.pop();
      await tester.pumpAndSettle();
      expect(find.text('T2'), findsOneWidget);
    });

    // An existing go_router bypass, which this package does not fix (it happens without
    // `runRedirect` too, and in a plain GoRouter): go_router restores a pushed location with
    // `findMatch` and skips its redirect on a refresh, so the guarded page shows without its guard.
    // Skipped until go_router fixes it: fespalier/fespalier#258.
    testWidgets(
      'a refresh after a pushed failure runs the guard again (go_router '
      'bypass, fespalier/fespalier#258)',
      (tester) async {
        inbox = (ref) => throw StateError('boom');
        final (:router, :answer, :done) = await fail(tester, 'push');
        expect(tester.takeException(), isA<StateError>());
        expect(inboxRuns, 1);
        router.refresh();
        await tester.pumpAndSettle();
        expect(inboxRuns, 2);
        expect(find.textContaining('INBOX'), findsNothing);
      },
      skip: true,
    );

    testWidgets('a pushed failure enters nothing and leaves nothing: the page '
        'under the error view stays', (tester) async {
      inbox = (ref) => throw StateError('boom');
      final events = <String>[];
      final r = router(initial: '/under');
      observeAttach(
        r,
        (uri) => [
          RouteHooks(
            'observe.dart',
            onEnter: (_, _) => events.add('enter ${uri.path}'),
            onLeave: (_) => events.add('leave ${uri.path}'),
            onFocus: (_) => events.add('focus ${uri.path}'),
          ),
        ],
      );
      await pumpRouter(tester, r);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      expect(events, ['enter /under', 'enter /other']);
      unawaited(r.push<void>('/inbox'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      // The failed location was never a page: no enter for it, and `/other` was not left.
      expect(events, ['enter /under', 'enter /other']);
      r.pop();
      await tester.pumpAndSettle();
      expect(events, ['enter /under', 'enter /other']);
      expect(find.text('OTHER'), findsOneWidget);
    });

    testWidgets('pushReplacement over a single page is the router\'s own '
        'error: the retry refreshes', (tester) async {
      var failFirst = true;
      inbox = (ref) {
        if (failFirst) {
          failFirst = false;
          throw StateError('boom');
        }
        return null;
      };
      final r = router(initial: '/under');
      await pumpRouter(tester, r);
      unawaited(r.pushReplacement<void>('/inbox'));
      await tester.pumpAndSettle();
      expect(r.routerDelegate.currentConfiguration.error, isA<GuardFailure>());
      expect(tester.takeException(), isA<StateError>());
      await tester.tap(find.text('ERROR Bad state: boom'));
      await tester.pumpAndSettle();
      expect(find.text('INBOX'), findsOneWidget);
      expect(r.routerDelegate.currentConfiguration.error, isNull);
    });
  });
}
