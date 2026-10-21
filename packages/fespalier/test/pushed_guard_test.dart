// A guard on a pushed page holds after go_router's refresh (fespalier/fespalier#258). The two
// canaries are plain go_router, with no fespalier: they assert what go_router does today, and fail on
// purpose when a go_router release runs a pushed page's redirect on a refresh (then fespalier's
// handling is only a second check, and docs/guards.md's "what go_router still skips" must change).
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  group('the Future of a push whose page a re-run replaces', () {
    GoRouter picker() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(
          path: '/pick',
          redirect: (context, state) => runRedirect(
            () => refGuard(
              context,
              'g1@pick',
              (ref) => ref.watch(_signedIn) ? null : '/other',
            ),
          ),
          builder: (_, _) => const Text('PICK'),
        ),
        GoRoute(path: '/other', builder: (_, _) => const Text('OTHER')),
      ],
    );

    testWidgets('completes with what the page in its place pops with', (
      tester,
    ) async {
      final r = picker();
      final c = await pumpRouter(tester, r);
      final done = <int?>[];
      unawaited(r.push<int>('/pick').then(done.add));
      await tester.pumpAndSettle();
      c.read(_signedIn.notifier).set(false);
      await tester.pumpAndSettle();
      expect(find.text('OTHER'), findsOneWidget);
      r.pop(7);
      await tester.pumpAndSettle();
      expect(done, [7]);
    });

    testWidgets('a result of another type than the push asked for completes '
        'it with null, and a debug build reports it', (tester) async {
      final r = picker();
      final c = await pumpRouter(tester, r);
      final done = <int?>[];
      final errors = <Object>[];
      unawaited(r.push<int>('/pick').then(done.add, onError: errors.add));
      await tester.pumpAndSettle();
      c.read(_signedIn.notifier).set(false);
      await tester.pumpAndSettle();
      expect(find.text('OTHER'), findsOneWidget);
      // The page in place pops with a String, which a Future of int? cannot hold.
      r.pop('not an int');
      await tester.pumpAndSettle();
      expect(errors, isEmpty);
      expect(done, [null], reason: 'the push does not hang');
      final report = tester.takeException();
      expect(report, isA<FlutterError>());
      expect(report.toString(), contains('String'));
    });
  });

  group('what lies over a pushed page when its guard runs again', () {
    var states = 0;
    var runs = 0;

    /// The evaluation at which the guard of `/admin` throws (0: never).
    var throwAt = 0;

    GoRouter admin({required bool isAsync}) => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(
          path: '/admin',
          redirect: (context, state) => runRedirect(
            () => refGuard(context, 'g1@admin', (ref) {
              runs++;
              final ok = ref.watch(_signedIn);
              if (throwAt != 0 && runs >= throwAt) throw StateError('boom');
              final answer = ok ? null : '/login';
              return isAsync ? Future<String?>.value(answer) : answer;
            }),
          ),
          builder: (context, state) =>
              refusedView(context, state) ?? _Counter(onState: () => states++),
        ),
        GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
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
      throwAt = 0;
    });

    /// A dialog over the page on top, as the app's own code shows one.
    Future<void> showSecret(WidgetTester tester) async {
      final context = tester.element(find.byType(_Counter));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const Text('SECRET DIALOG'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SECRET DIALOG'), findsOneWidget);
    }

    testWidgets('a re-run in a tab closes a dialog of the tab\'s own '
        'navigator too', (tester) async {
      final r = GoRouter(
        initialLocation: '/tab',
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (context, state, shell) => shell,
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: '/tab',
                    builder: (_, _) => const Text('TAB'),
                    routes: [
                      GoRoute(
                        path: 'admin',
                        redirect: (context, state) => runRedirect(
                          () => refGuard(
                            context,
                            'g1@tab-admin',
                            (ref) =>
                                ref.watch(_signedIn) ? null : '/tab/denied',
                          ),
                        ),
                        builder: (context, state) =>
                            refusedView(context, state) ??
                            _Counter(onState: () => states++),
                      ),
                      GoRoute(
                        path: 'denied',
                        builder: (_, _) => const Text('DENIED'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
        ],
      );
      final c = await pumpRouter(tester, r);
      unawaited(r.push<void>('/tab/admin'));
      await tester.pumpAndSettle();
      expect(find.text('COUNT 0'), findsOneWidget);
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(_Counter)),
          useRootNavigator: false,
          builder: (_) => const Text('SECRET DIALOG'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SECRET DIALOG'), findsOneWidget);
      c.read(_signedIn.notifier).set(false);
      await tester.pumpAndSettle();
      expect(find.text('DENIED'), findsOneWidget);
      expect(find.text('SECRET DIALOG'), findsNothing);
    });

    for (final isAsync in [false, true]) {
      final kind = isAsync ? 'async' : 'sync';

      testWidgets('a re-run that moves the page closes the dialog over it '
          '($kind guard)', (tester) async {
        final r = admin(isAsync: isAsync);
        final c = await pumpRouter(tester, r);
        unawaited(r.push<void>('/admin'));
        await tester.pumpAndSettle();
        await showSecret(tester);
        c.read(_signedIn.notifier).set(false);
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/login');
        expect(find.text('LOGIN'), findsOneWidget);
        expect(find.text('SECRET DIALOG'), findsNothing);
      });

      testWidgets('a re-run that fails closes the dialog over the page and '
          'shows the error view ($kind guard)', (tester) async {
        final r = admin(isAsync: isAsync);
        final c = await pumpRouter(tester, r);
        unawaited(r.push<void>('/admin'));
        await tester.pumpAndSettle();
        await showSecret(tester);
        // The push was the first run, the change the second, and the router's own run the third.
        throwAt = 3;
        c.read(_signedIn.notifier).set(false);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isA<StateError>());
        expect(find.text('ERROR'), findsOneWidget);
        expect(find.text('SECRET DIALOG'), findsNothing);
      });

      testWidgets('a re-run that passes again keeps the dialog and the '
          'page\'s state ($kind guard)', (tester) async {
        final r = admin(isAsync: isAsync);
        await pumpRouter(tester, r);
        unawaited(r.push<void>('/admin'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('COUNT 0'));
        await tester.pump();
        await showSecret(tester);
        r.refresh();
        await tester.pumpAndSettle();
        // The refresh restored the page without its redirect, and its guard ran again and passed.
        expect(runs, 2);
        expect(find.text('SECRET DIALOG'), findsOneWidget);
        expect(find.text('COUNT 1'), findsOneWidget);
        expect(states, 1);
      });
    }
  });
  group('a way back while the re-run of a pushed page waits', () {
    var states = 0;
    var runs = 0;

    /// When set, the guard of `/admin` answers once it completes (an async guard that takes a while).
    Completer<void>? gate;

    /// What the guard answers: null lets the page through.
    String? answerWith;

    /// How often the `Future` of the push that opened `/admin` completed.
    var completed = 0;

    /// Whether the guard throws once it answers.
    var failing = false;

    GoRouter admin({required bool isAsync}) => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(
          path: '/admin',
          redirect: (context, state) => runRedirect(
            () => refGuard(context, 'g1@admin', (ref) {
              runs++;
              ref.watch(_signedIn);
              if (!isAsync) return answerWith;
              final wait = gate;
              if (wait == null) return Future<String?>.value(answerWith);
              final answer = answerWith;
              return wait.future.then<String?>((_) {
                if (failing) throw StateError('the guard failed');
                return answer;
              });
            }),
          ),
          builder: (context, state) =>
              refusedView(context, state) ??
              Scaffold(
                appBar: AppBar(title: const Text('ADMIN')),
                body: _Counter(onState: () => states++),
              ),
        ),
        GoRoute(
          path: '/x',
          builder: (_, _) =>
              Scaffold(appBar: AppBar(), body: const Text('PAGE X')),
        ),
        GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
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
      gate = null;
      answerWith = null;
      completed = 0;
      failing = false;
    });

    /// `/admin` pushed, `/x` pushed over it and popped: go_router shows `/admin` again without its
    /// redirect, and its guard runs again after the frame. With [wait] the guard is still on its way.
    Future<GoRouter> reRunning(
      WidgetTester tester, {
      required bool isAsync,
      required bool wait,
    }) async {
      final r = admin(isAsync: isAsync);
      await pumpRouter(tester, r);
      unawaited(r.push<void>('/admin').then((_) => completed++));
      await tester.pumpAndSettle();
      expect(find.text('ADMIN'), findsOneWidget);
      unawaited(r.push<void>('/x'));
      await tester.pumpAndSettle();
      expect(find.text('PAGE X'), findsOneWidget);
      if (wait) gate = Completer<void>();
      final before = runs;
      r.pop();
      await tester.pump();
      await tester.pump();
      expect(find.text('ADMIN'), findsOneWidget);
      expect(runs, before + 1, reason: 'the re-run started');
      return r;
    }

    /// The stack is `/home` alone: nothing is pushed over it.
    void expectHome(GoRouter r) {
      final config = r.routerDelegate.currentConfiguration;
      expect(config.matches.whereType<ImperativeRouteMatch>(), isEmpty);
      expect(config.uri.toString(), '/home');
    }

    for (final isAsync in [false, true]) {
      final kind = isAsync ? 'async' : 'sync';

      testWidgets('the back button of the app bar leaves the page and the '
          're-run does not bring it back ($kind guard)', (tester) async {
        final r = await reRunning(tester, isAsync: isAsync, wait: isAsync);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expectHome(r);
        expect(find.text('ADMIN'), findsNothing);
        expect(completed, 1, reason: 'the push completed when its page popped');
        gate?.complete();
        await tester.pumpAndSettle();
        expectHome(r);
        expect(find.text('ADMIN'), findsNothing);
        expect(find.text('HOME'), findsOneWidget);
        expect(states, 1, reason: 'the page was never made again');
        expect(completed, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Navigator.maybePop leaves the page the same way '
          '($kind guard)', (tester) async {
        final r = await reRunning(tester, isAsync: isAsync, wait: isAsync);
        final navigator = Navigator.of(tester.element(find.text('ADMIN')));
        expect(await navigator.maybePop(), isTrue);
        await tester.pumpAndSettle();
        gate?.complete();
        await tester.pumpAndSettle();
        expectHome(r);
        expect(find.text('ADMIN'), findsNothing);
        expect(completed, 1);
      });

      testWidgets('GoRouter.pop leaves the page and nothing brings it back '
          '($kind guard)', (tester) async {
        final r = await reRunning(tester, isAsync: isAsync, wait: isAsync);
        r.pop();
        await tester.pumpAndSettle();
        gate?.complete();
        await tester.pumpAndSettle();
        expectHome(r);
        expect(find.text('ADMIN'), findsNothing);
        expect(completed, 1);
      });

      testWidgets('the system back leaves the page and nothing brings it '
          'back ($kind guard)', (tester) async {
        final r = await reRunning(tester, isAsync: isAsync, wait: isAsync);
        await _systemBack(tester);
        gate?.complete();
        await tester.pumpAndSettle();
        expectHome(r);
        expect(find.text('ADMIN'), findsNothing);
        expect(completed, 1);
      });
    }

    testWidgets('a guard that now sends the page elsewhere does not bring a '
        'page back that the person left', (tester) async {
      final r = await reRunning(tester, isAsync: true, wait: true);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expectHome(r);
      answerWith = '/login';
      gate!.complete();
      await tester.pumpAndSettle();
      expectHome(r);
      expect(find.text('LOGIN'), findsNothing);
      expect(find.text('ADMIN'), findsNothing);
      expect(completed, 1);
    });

    testWidgets('a guard that fails does not bring a page back that the '
        'person left, and shows no error view', (tester) async {
      final r = await reRunning(tester, isAsync: true, wait: true);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expectHome(r);
      failing = true;
      gate!.complete();
      await tester.pumpAndSettle();
      expectHome(r);
      expect(find.text('ADMIN'), findsNothing);
      expect(find.text('ERROR'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a back that the person makes before the guard answers, with '
        'a page pushed on top meanwhile, keeps both leaves', (tester) async {
      final r = await reRunning(tester, isAsync: true, wait: true);
      // The person goes on to another page over the waiting one, and back to home from there.
      unawaited(r.push<void>('/x'));
      await tester.pumpAndSettle();
      gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('PAGE X'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expectHome(r);
      expect(find.text('ADMIN'), findsNothing);
    });
  });
}

class _Flag extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) => state = value;
}

/// Whether someone is signed in, which a guard watches.
final _signedIn = NotifierProvider<_Flag, bool>(_Flag.new);

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

/// The system's back button, as the engine sends it.
Future<void> _systemBack(WidgetTester tester) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}
