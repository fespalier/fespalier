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

import 'support/attach_order.dart';

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

  // The tests of fespalier's own handling run in every order of what listens to the router before
  // the Router widget does (test/support/attach_order.dart).
  inEveryOrder(pushedPageGroups);
}

void pushedPageGroups() {
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
        await pumpRouter(tester, attached(r));
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
        await pumpRouter(tester, attached(r));
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
      await pumpRouter(tester, attached(r));
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

  // go_router gives a plain list, with no pushed page in it, when `replace` or `pushReplacement` takes
  // the base page's place. The guards that navigation evaluated are the base's, and they stay watched
  // as they are after a `go`: no entry carries the completer of that request.
  group('a replace over a lone base page keeps its guard watched', () {
    GoRouter router() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
        GoRoute(
          path: '/admin',
          redirect: (context, state) => runRedirect(
            () => refGuard(
              context,
              'g@admin',
              (ref) => ref.watch(_signedIn) ? null : '/login',
            ),
          ),
          builder: (context, state) =>
              refusedView(context, state) ?? const Text('ADMIN'),
        ),
      ],
    );

    for (final how in ['pushReplacement', 'replace']) {
      testWidgets('$how: a sign-out moves the page', (tester) async {
        final r = router();
        final c = await pumpRouter(tester, attached(r));
        if (how == 'replace') {
          unawaited(r.replace<void>('/admin'));
        } else {
          unawaited(r.pushReplacement<void>('/admin'));
        }
        await tester.pumpAndSettle();
        expect(find.text('ADMIN'), findsOneWidget);
        expect(
          r.routerDelegate.currentConfiguration.matches
              .whereType<ImperativeRouteMatch>(),
          isEmpty,
          reason: 'go_router left no pushed page',
        );
        c.read(_signedIn.notifier).set(false);
        await tester.pumpAndSettle();
        expect(find.text('LOGIN'), findsOneWidget);
        expect(find.text('ADMIN'), findsNothing);
      });
    }
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
      final c = await pumpRouter(tester, attached(r));
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
      final c = await pumpRouter(tester, attached(r));
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

    // A re-run that moves a page closes what the Navigator would close if that page were removed: the
    // routes without a page over it, on the navigator the page is in. A dialog opened on the root
    // navigator (`showDialog`'s default) over a page in a tab is over the tab layout's page, not over
    // the pushed page, and stays, as it does when a base page of the tab moves.
    group('the dialogs over a page in a tab', () {
      /// When set, the guard of `/tab/admin` answers once it completes.
      Completer<void>? tabGate;

      /// The tab layout, once a router built it.
      StatefulNavigationShell? tabShell;

      /// `/tab/admin` has a guard on [_signedIn], and is pushed inside the tab, or on the root
      /// navigator ([onRoot]).
      GoRouter tabs({required bool isAsync, bool onRoot = false}) {
        final rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');
        return GoRouter(
          initialLocation: '/tab',
          navigatorKey: rootKey,
          routes: [
            StatefulShellRoute.indexedStack(
              builder: (context, state, shell) {
                tabShell = shell;
                return shell;
              },
              branches: [
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/tab',
                      builder: (_, _) => const Text('TAB'),
                      routes: [
                        GoRoute(
                          path: 'admin',
                          parentNavigatorKey: onRoot ? rootKey : null,
                          redirect: (context, state) => runRedirect(
                            () => refGuard(context, 'g1@tab-admin', (ref) {
                              final answer = ref.watch(_signedIn)
                                  ? null
                                  : '/tab/denied';
                              if (!isAsync) return answer;
                              final wait = tabGate;
                              return wait == null
                                  ? Future<String?>.value(answer)
                                  : wait.future.then<String?>((_) => answer);
                            }),
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
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/other-tab',
                      builder: (_, _) => const Text('OTHER TAB'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
      }

      setUp(() {
        tabGate = null;
        tabShell = null;
      });

      /// The page is pushed, and its guard is asked again because the person signed out. An asynchronous
      /// guard takes a while, and the app opens its dialog (`onRootNavigator` or not) meanwhile; a
      /// synchronous one answers at once, so the dialog is there before.
      Future<void> dialogWhileWaiting(
        WidgetTester tester,
        GoRouter r, {
        required bool isAsync,
        required bool onRootNavigator,
      }) async {
        final c = await pumpRouter(tester, attached(r));
        unawaited(r.push<void>('/tab/admin'));
        await tester.pumpAndSettle();
        expect(find.text('COUNT 0'), findsOneWidget);
        Future<void> showSignedOut() async {
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(_Counter)),
              useRootNavigator: onRootNavigator,
              builder: (_) => const Text('SIGNED OUT DIALOG'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('SIGNED OUT DIALOG'), findsOneWidget);
        }

        if (isAsync) {
          tabGate = Completer<void>();
          c.read(_signedIn.notifier).set(false);
          await tester.pump();
          await showSignedOut();
          tabGate!.complete();
        } else {
          await showSignedOut();
          c.read(_signedIn.notifier).set(false);
        }
        await tester.pumpAndSettle();
        expect(find.text('DENIED'), findsOneWidget);
      }

      testWidgets('a page in a tab that the person leaves while its guard '
          'waits is not brought back', (tester) async {
        final r = tabs(isAsync: true);
        await pumpRouter(tester, attached(r));
        unawaited(r.push<void>('/tab/admin'));
        await tester.pumpAndSettle();
        unawaited(r.push<void>('/tab/denied'));
        await tester.pumpAndSettle();
        tabGate = Completer<void>();
        r.pop();
        await tester.pumpAndSettle();
        expect(find.text('COUNT 0'), findsOneWidget);
        // The tab's own navigator pops the page: the router is not asked.
        final navigator = Navigator.of(tester.element(find.byType(_Counter)));
        expect(await navigator.maybePop(), isTrue);
        await tester.pumpAndSettle();
        expect(find.text('TAB'), findsOneWidget);
        tabGate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('TAB'), findsOneWidget);
        expect(find.text('COUNT 0'), findsNothing);
        expect(find.text('DENIED'), findsNothing);
      });

      testWidgets('a tab switch while the guard of a page in a tab waits '
          'is not undone by the re-run', (tester) async {
        final r = tabs(isAsync: true);
        await pumpRouter(tester, attached(r));
        unawaited(r.push<void>('/tab/admin'));
        await tester.pumpAndSettle();
        unawaited(r.push<void>('/tab/denied'));
        await tester.pumpAndSettle();
        tabGate = Completer<void>();
        r.pop();
        await tester.pumpAndSettle();
        expect(find.text('COUNT 0'), findsOneWidget);
        tabShell!.goBranch(1);
        await tester.pumpAndSettle();
        expect(find.text('OTHER TAB'), findsOneWidget);
        tabGate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('OTHER TAB'), findsOneWidget);
        expect(find.text('COUNT 0'), findsNothing);
        // Back on the first tab the page is shown again, and its guard runs again.
        tabGate = null;
        tabShell!.goBranch(0);
        await tester.pumpAndSettle();
        expect(find.text('COUNT 0'), findsOneWidget);
      });

      for (final isAsync in [false, true]) {
        final kind = isAsync ? 'async' : 'sync';

        testWidgets('a dialog on the root navigator stays when the re-run '
            'moves the page ($kind guard)', (tester) async {
          await dialogWhileWaiting(
            tester,
            tabs(isAsync: isAsync),
            isAsync: isAsync,
            onRootNavigator: true,
          );
          expect(find.text('SIGNED OUT DIALOG'), findsOneWidget);
        });

        testWidgets('a dialog of the tab\'s own navigator is closed when the '
            're-run moves the page ($kind guard)', (tester) async {
          await dialogWhileWaiting(
            tester,
            tabs(isAsync: isAsync),
            isAsync: isAsync,
            onRootNavigator: false,
          );
          expect(find.text('SIGNED OUT DIALOG'), findsNothing);
        });

        testWidgets('a page pushed on the root navigator closes the dialog '
            'on it ($kind guard)', (tester) async {
          await dialogWhileWaiting(
            tester,
            tabs(isAsync: isAsync, onRoot: true),
            isAsync: isAsync,
            onRootNavigator: true,
          );
          expect(find.text('SIGNED OUT DIALOG'), findsNothing);
        });
      }
    });

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
      final c = await pumpRouter(tester, attached(r));
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
        final c = await pumpRouter(tester, attached(r));
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
        final c = await pumpRouter(tester, attached(r));
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
        await pumpRouter(tester, attached(r));
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

    /// How often the guard of `/counted`, a page of the app that a `go` leads to, ran.
    var countedRuns = 0;

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
        GoRoute(
          path: '/counted',
          redirect: (context, state) => runRedirect(
            () => refGuard(context, 'g2@counted', (ref) {
              countedRuns++;
              ref.watch(_signedIn);
              return null;
            }),
          ),
          builder: (_, _) => const Text('COUNTED'),
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
      countedRuns = 0;
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
      await pumpRouter(tester, attached(r));
      unawaited(r.push<void>('/admin').then((_) => completed++));
      await tester.pumpAndSettle();
      expect(find.text('ADMIN'), findsOneWidget);
      unawaited(r.push<void>('/x'));
      await tester.pumpAndSettle();
      expect(find.text('PAGE X'), findsOneWidget);
      if (wait) gate = Completer<void>();
      final before = runs;
      r.pop();
      await tester.pumpAndSettle();
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

    testWidgets('a go while the guard waits: the page it leads to is guarded '
        'once and nothing comes back', (tester) async {
      final r = await reRunning(tester, isAsync: true, wait: true);
      r.go('/counted');
      await tester.pumpAndSettle();
      expect(find.text('COUNTED'), findsOneWidget);
      expect(countedRuns, 1);
      gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('COUNTED'), findsOneWidget);
      expect(find.text('ADMIN'), findsNothing);
      expect(countedRuns, 1, reason: 'the router was not asked again');
    });

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

  // A pushed page that go_router shows again without its redirect is run again after the frame, once.
  // A reader that listens to the router before the Router widget (DevTools, telemetry: the
  // groups run with each of them, see test/support/attach_order.dart) judges the commit first, and the
  // widget's report of the configuration it committed then comes after the callback that starts the
  // re-run: it replaces the route information the re-run put in the provider with an encoded Map before an
  // asynchronous guard answers. The re-run is the router's own navigation all the same; taken for a
  // commit nobody asked for, its landing started another re-run, and so on, every frame, with the
  // guard and the page rebuilt each time and `leave()` asked each time.
  group('a pushed page with an asynchronous guard settles', () {
    var runs = 0;
    var built = 0;
    var asked = 0;
    var fails = false;

    GoRouter router() => GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(
          path: '/other',
          builder: (_, _) =>
              Scaffold(appBar: AppBar(), body: const Text('OTHER')),
        ),
        for (final path in ['/ga', '/gl', '/fa'])
          GoRoute(
            path: path,
            redirect: (context, state) => runRedirect(
              () => refGuard(context, 'g@$path', (ref) {
                runs++;
                if (path == '/fa' && fails) {
                  return Future<String?>.error(StateError('the guard failed'));
                }
                return Future<String?>.value(null);
              }),
            ),
            // A page with a `leave.dart` (which lets everything go) and one without.
            onExit: path == '/gl'
                ? (context, state) =>
                      leaveExit(context, state, 'gl/leave.dart', (ref, page) {
                        asked++;
                        return true;
                      })
                : null,
            builder: (context, state) =>
                refusedView(context, state) ??
                Builder(
                  builder: (_) {
                    built++;
                    return Text('PAGE $path');
                  },
                ),
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
      runs = 0;
      built = 0;
      asked = 0;
      fails = false;
    });

    /// How often the router committed during [body] and the 30 frames after it.
    Future<int> commitsDuring(
      WidgetTester tester,
      GoRouter r,
      FutureOr<void> Function() body,
    ) async {
      var commits = 0;
      void count() => commits++;
      r.routerDelegate.addListener(count);
      await body();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      r.routerDelegate.removeListener(count);
      return commits;
    }

    for (final path in ['/ga', '/gl']) {
      testWidgets('$path, uncovered by a pop: its guard runs once more, in two '
          'commits, and nothing is left to do', (tester) async {
        final r = router();
        await pumpRouter(tester, attached(r));
        unawaited(r.push<void>(path));
        await tester.pumpAndSettle();
        unawaited(r.push<void>('/other'));
        await tester.pumpAndSettle();
        final before = (runs: runs, built: built);
        final commits = await commitsDuring(tester, r, r.pop);
        // The pop, and the re-run of the page that go_router showed without its redirect.
        expect(commits, 2);
        expect(runs, before.runs + 1);
        expect(asked, 0, reason: 'a re-run that passes again asks nothing');
        expect(built - before.built, lessThanOrEqualTo(2));
        expect(find.text('PAGE $path'), findsOneWidget);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });

      testWidgets('$path, after a refresh(): its guard runs once more, in two '
          'commits, and nothing is left to do', (tester) async {
        final r = router();
        await pumpRouter(tester, attached(r));
        unawaited(r.push<void>(path));
        await tester.pumpAndSettle();
        final before = (runs: runs, built: built);
        final commits = await commitsDuring(tester, r, r.refresh);
        // The restore go_router makes without the redirect, and the re-run of the page.
        expect(commits, 2);
        expect(runs, before.runs + 1);
        // The restore replaces the page with a new entry, which asks `leave()` once; the re-run, which
        // passes again, asks nothing.
        expect(asked, path == '/gl' ? 1 : 0);
        expect(built - before.built, lessThanOrEqualTo(2));
        expect(find.text('PAGE $path'), findsOneWidget);
        expect(tester.binding.hasScheduledFrame, isFalse);
        await tester.pumpAndSettle();
      });
    }

    testWidgets('a push whose async guard failed, the guard fixed, then a '
        'refresh(): the page is shown, built once, and the app settles', (
      tester,
    ) async {
      final r = router();
      await pumpRouter(tester, attached(r));
      fails = true;
      unawaited(r.push<void>('/fa'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isA<StateError>());
      expect(find.text('ERROR'), findsOneWidget);
      expect(built, 0, reason: 'a failed push never builds the page');
      fails = false;
      final commits = await commitsDuring(tester, r, r.refresh);
      expect(commits, 2);
      expect(runs, 2);
      expect(built, 1);
      expect(find.text('PAGE /fa'), findsOneWidget);
      expect(find.text('ERROR'), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpAndSettle();
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
