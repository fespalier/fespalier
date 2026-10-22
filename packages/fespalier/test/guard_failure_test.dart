// A guard that fails (since 0.21.0): what go_router gets, what the error route shows, the one
// report (made in every build mode) and the retry. The zone tests stand in for go_router 17.2.3 to 18.1.0, which ran a
// redirect in an error zone of their own; the widget tests run on every go_router.
import 'dart:async';
import 'dart:io';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/attach_order.dart';

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

/// What the guard of `/inbox` answers, how often it ran, and how often its page was built.
var inboxRuns = 0;
var inboxBuilt = 0;
GuardResult Function(Ref ref) inbox = (ref) => null;

/// What the `/plain` guard answers: a `ProviderContainer` guard, called with the app's container.
GuardResult Function() plainAnswer = () => null;
final plainProvider = Provider<GuardResult>(
  (ref) => plainAnswer(),
  retry: (_, _) => null,
);
GuardResult plainGuard(ProviderContainer container) =>
    container.read(plainProvider);

/// Whether someone is signed in, which the first guard of `/admin` watches, and how often it ran.
class Flag extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool value) => state = value;
}

final signedIn = NotifierProvider<Flag, bool>(Flag.new);
var adminRuns = 0;

/// The retry of the last view built, and the state of the last error page built.
VoidCallback? heldRetry;
GoRouterState? lastErrorState;

Widget _inboxPage(GoRouterState state) {
  inboxBuilt++;
  return Text(
    'INBOX${state.extra == null ? '' : ' ${state.uri.query} ${state.extra}'}',
  );
}

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
  if (uri.path != '/inbox' && uri.path != '/plain' && uri.path != '/admin') {
    return null;
  }
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
      // The generated page builder of a guarded route: `refusedView(context, state) ?? <page>`.
      builder: (context, state) =>
          refusedView(context, state) ?? _inboxPage(state),
    ),
    GoRoute(
      path: '/plain',
      redirect: (context, state) => runRedirect(
        () => plainGuard(ProviderScope.containerOf(context, listen: false)),
      ),
      builder: (_, _) => const Text('PLAIN'),
    ),
    // Two guards, as the generator writes them: the first watches `signedIn` and passes, the second
    // is the `/plain` one and fails.
    GoRoute(
      path: '/admin',
      redirect: (context, state) => runRedirect(
        () => firstRedirect([
          () => refGuard(context, 'g1@admin', (ref) {
            adminRuns++;
            return ref.watch(signedIn) ? null : '/login';
          }),
          () => plainGuard(ProviderScope.containerOf(context, listen: false)),
        ]),
      ),
      builder: (_, _) => const Text('ADMIN'),
    ),
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
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
    inboxBuilt = 0;
    adminRuns = 0;
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
      // mode as long as the code that makes it names no build mode and asserts nothing.
      // SentryFlutter.init hears it through FlutterError.onError there.
      final source = File('lib/src/guards.dart').readAsStringSync();
      expect(source, isNot(contains('kDebugMode')));
      expect(source, isNot(contains('kProfileMode')));
      expect(source, isNot(contains('kReleaseMode')));
      // The path that reports: the error page, up to the retry that follows it.
      final start = source.indexOf('Widget routerErrorPage(');
      final end = source.indexOf('void _retry(');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      expect(source.substring(start, end), isNot(contains('assert(')));
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
  // The pushed navigations run in every order of what listens to the router before the Router
  // widget does (test/support/attach_order.dart).
  inEveryOrder(
    pushedNavigations,
    // A test of the group attaches the lifecycle watch itself, with hooks of its own.
    orders: const [
      AttachFirst.nothing,
      AttachFirst.devTools,
      AttachFirst.telemetry,
    ],
  );
}

void pushedNavigations() {
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
      await pumpRouter(tester, attached(r));
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
        // The retry keeps the entry the error view stood for (its key), so the Future of the
        // navigation that failed completes when the page in its place pops.
        expect(done, isEmpty);
        // The stack below is what it was: back to the page under the new one.
        router.pop();
        await tester.pumpAndSettle();
        expect(done, [null]);
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
        expect(done, isEmpty);
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
      await pumpRouter(tester, attached(r));
      final answer = r.push<Object?>('/inbox');
      var done = false;
      unawaited(answer.whenComplete(() => done = true));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      await tester.tap(find.text('ERROR Bad state: boom'));
      await tester.pumpAndSettle();
      expect(find.text('INBOX'), findsOneWidget);
      expect(done, isFalse);
      r.pop();
      await tester.pumpAndSettle();
      expect(done, isTrue);
      expect(find.text('T2'), findsOneWidget);
    });

    // go_router restores a pushed location with `findMatch` on a refresh and skips its redirect, so the
    // guarded page would show without its guard (fespalier/fespalier#258; the general case is
    // flutter/flutter#133985). fespalier holds the page back and runs its guard again.
    testWidgets(
      'a refresh after a pushed failure runs the guard again and never builds '
      'the guarded page (fespalier/fespalier#258)',
      (tester) async {
        inbox = (ref) => throw StateError('boom');
        final (:router, :answer, :done) = await fail(tester, 'push');
        expect(tester.takeException(), isA<StateError>());
        expect(inboxRuns, 1);
        expect(inboxBuilt, 0);
        router.refresh();
        await tester.pumpAndSettle();
        expect(inboxRuns, 2, reason: 'refresh() must run the guard again');
        expect(
          inboxBuilt,
          0,
          reason: 'the guarded page is not built unless its guard passes',
        );
        expect(find.textContaining('INBOX'), findsNothing);
        expect(find.text('ERROR Bad state: boom'), findsOneWidget);
        // The guard failed again: a second report, once.
        expect(tester.takeException(), isA<StateError>());
        expect(tester.takeException(), isNull);
        expect(done, isEmpty);
      },
    );

    testWidgets(
      'a refresh after a pushed failure shows the page once its guard passes, '
      'and the push completes when that page pops',
      (tester) async {
        inbox = (ref) => throw StateError('boom');
        final (:router, :answer, :done) = await fail(tester, 'push');
        expect(tester.takeException(), isA<StateError>());
        inbox = (ref) => null;
        router.refresh();
        await tester.pumpAndSettle();
        expect(inboxRuns, 2);
        expect(find.text('INBOX x=1 EX'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(done, isEmpty, reason: 'the page it started is still open');
        router.pop();
        await tester.pumpAndSettle();
        expect(done, [null]);
        expect(find.text('OTHER'), findsOneWidget);
      },
    );

    testWidgets(
      'a refresh after a pushed async failure holds the page until the answer',
      (tester) async {
        inbox = (ref) async {
          await null;
          throw StateError('boom');
        };
        final (:router, :answer, :done) = await fail(tester, 'push');
        expect(tester.takeException(), isA<StateError>());
        router.refresh();
        await tester.pump();
        expect(find.textContaining('INBOX'), findsNothing);
        await tester.pumpAndSettle();
        expect(inboxRuns, 2);
        expect(inboxBuilt, 0);
        expect(find.text('ERROR Bad state: boom'), findsOneWidget);
        expect(tester.takeException(), isA<StateError>());
      },
    );

    testWidgets('a refresh after a push from a tab holds the failed page too', (
      tester,
    ) async {
      inbox = (ref) => throw StateError('boom');
      final r = router(initial: '/t2');
      await pumpRouter(tester, attached(r));
      unawaited(r.push<void>('/inbox'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      r.refresh();
      await tester.pumpAndSettle();
      expect(inboxRuns, 2);
      expect(inboxBuilt, 0);
      expect(find.textContaining('INBOX'), findsNothing);
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      expect(tester.takeException(), isA<StateError>());
    });

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
      await pumpRouter(tester, attached(r));
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      expect(events, ['enter /under', 'enter /other']);
      unawaited(r.push<void>('/inbox'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('ERROR Bad state: boom'), findsOneWidget);
      // The failed location was never a page: no enter for it, `/other` was not left, and it
      // gets no focus while the error view covers it.
      expect(events, ['enter /under', 'enter /other']);
      r.pop();
      await tester.pumpAndSettle();
      // The error view is gone: `/other` is the visible page again.
      expect(events, ['enter /under', 'enter /other', 'focus /other']);
      expect(find.text('OTHER'), findsOneWidget);
    });

    for (final kind in ['pushReplacement', 'replace']) {
      testWidgets('$kind: the replaced page leaves, and the page under it gets '
          'its focus when the error view closes, not before', (tester) async {
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
        await pumpRouter(tester, attached(r));
        unawaited(r.push<void>('/other'));
        await tester.pumpAndSettle();
        events.clear();
        unawaited(
          kind == 'replace'
              ? r.replace<void>('/inbox')
              : r.pushReplacement<void>('/inbox'),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isA<StateError>());
        expect(find.text('ERROR Bad state: boom'), findsOneWidget);
        // `/other` was replaced before the guard ran, so it is gone. `/under` is under the error
        // view, which covers it: no focus yet.
        expect(events, ['leave /other']);
        r.pop();
        await tester.pumpAndSettle();
        expect(events, ['leave /other', 'focus /under']);
        expect(find.text('UNDER'), findsOneWidget);
      });
    }

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
      await pumpRouter(tester, attached(r));
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

  group('a failed navigation closes the guards it touched', () {
    // The first guard of `/admin` watches `signedIn` and passed; the second failed. Its
    // subscription would stay open (the committed location "still runs" it), and a sign-out would
    // make fespalier refresh the router itself: with a pushed failure, go_router then restores the
    // guarded page without running a redirect (fespalier/fespalier#258).
    for (final kind in ['push', 'go']) {
      testWidgets('$kind: a sign-out afterwards re-runs nothing and refreshes '
          'nothing', (tester) async {
        plainAnswer = () => throw StateError('boom');
        final r = router();
        final c = await pumpRouter(tester, attached(r));
        if (kind == 'push') {
          unawaited(r.push<void>('/admin'));
        } else {
          r.go('/admin');
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isA<StateError>());
        expect(adminRuns, 1);
        expect(find.text('ERROR Bad state: boom'), findsOneWidget);
        c.read(signedIn.notifier).set(false);
        await tester.pumpAndSettle();
        // The first guard was closed with the failure: Riverpod did not run it again.
        expect(adminRuns, 1);
        expect(find.text('ADMIN'), findsNothing);
        expect(find.text('LOGIN'), findsNothing);
        expect(find.text('ERROR Bad state: boom'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a navigation that passes still keeps its guards live', (
      tester,
    ) async {
      plainAnswer = () => null;
      final r = router();
      final c = await pumpRouter(tester, attached(r));
      r.go('/admin');
      await tester.pumpAndSettle();
      expect(find.text('ADMIN'), findsOneWidget);
      c.read(signedIn.notifier).set(false);
      await tester.pumpAndSettle();
      expect(adminRuns, greaterThan(1));
      expect(find.text('LOGIN'), findsOneWidget);
    });
  });

  group('a retry pressed from a dialog or a sheet over the error view', () {
    Future<
      ({
        GoRouter router,
        Future<Object?> answer,
        List<Object?> done,
        BuildContext errorContext,
      })
    >
    failed(WidgetTester tester, String kind) async {
      var failFirst = true;
      inbox = (ref) {
        if (failFirst) {
          failFirst = false;
          throw StateError('boom');
        }
        return null;
      };
      final r = router(initial: '/under');
      await pumpRouter(tester, attached(r));
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      final done = <Object?>[];
      final Future<Object?> answer;
      if (kind == 'go') {
        r.go('/inbox?x=1');
        answer = Future<Object?>.value();
      } else {
        answer = r.push<Object?>('/inbox?x=1', extra: 'EX');
      }
      unawaited(answer.then(done.add));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      return (
        router: r,
        answer: answer,
        done: done,
        errorContext: tester.element(find.text('ERROR Bad state: boom')),
      );
    }

    for (final kind in ['push', 'go']) {
      testWidgets('$kind: a dialog is closed, and the retry runs', (
        tester,
      ) async {
        final f = await failed(tester, kind);
        unawaited(
          showDialog<void>(
            context: f.errorContext,
            builder: (_) => AlertDialog(
              content: TextButton(
                onPressed: heldRetry,
                child: const Text('RETRY FROM THE DIALOG'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('RETRY FROM THE DIALOG'));
        await tester.pumpAndSettle();
        expect(find.text('RETRY FROM THE DIALOG'), findsNothing);
        expect(inboxRuns, 2);
        expect(
          find.text(kind == 'push' ? 'INBOX x=1 EX' : 'INBOX'),
          findsOneWidget,
        );
        expect(find.textContaining('ERROR'), findsNothing);
        expect(tester.takeException(), isNull);
        if (kind == 'push') {
          // Back from the page the retry pushed leads to the page under it, not to the error view.
          f.router.pop();
          await tester.pumpAndSettle();
          expect(find.text('OTHER'), findsOneWidget);
          expect(find.textContaining('ERROR'), findsNothing);
        }
      });
    }

    testWidgets('push: a bottom sheet is closed, and the retry runs', (
      tester,
    ) async {
      final f = await failed(tester, 'push');
      unawaited(
        showModalBottomSheet<void>(
          context: f.errorContext,
          builder: (_) => TextButton(
            onPressed: heldRetry,
            child: const Text('RETRY FROM THE SHEET'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('RETRY FROM THE SHEET'));
      await tester.pumpAndSettle();
      expect(find.text('RETRY FROM THE SHEET'), findsNothing);
      expect(find.text('INBOX x=1 EX'), findsOneWidget);
      f.router.pop();
      await tester.pumpAndSettle();
      expect(find.text('OTHER'), findsOneWidget);
      expect(find.textContaining('ERROR'), findsNothing);
    });

    testWidgets('a page pushed over the error view keeps its dialog: the '
        'retry does nothing', (tester) async {
      final f = await failed(tester, 'push');
      final held = heldRetry!;
      unawaited(f.router.push<void>('/under'));
      await tester.pumpAndSettle();
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('UNDER')),
          builder: (_) => AlertDialog(
            content: TextButton(
              onPressed: held,
              child: const Text('RETRY FROM THE DIALOG'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('RETRY FROM THE DIALOG'));
      await tester.pumpAndSettle();
      expect(inboxRuns, 1);
      expect(find.text('RETRY FROM THE DIALOG'), findsOneWidget);
      expect(find.text('UNDER'), findsOneWidget);
    });
  });
}
