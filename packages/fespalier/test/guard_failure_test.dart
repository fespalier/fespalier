// A guard that fails (since 0.21.0): what go_router gets, what the error route shows, the one
// debug report and the retry. The zone tests stand in for go_router 17.2.3 to 18.1.0, which ran a
// redirect in an error zone of their own; the widget tests run on every go_router.
import 'dart:async';

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
      builder: (_, _) => const Text('INBOX'),
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
}
