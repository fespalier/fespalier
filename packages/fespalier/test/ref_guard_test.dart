import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Session extends Notifier<bool> {
  @override
  bool build() => true;
  void set(bool value) => state = value;
}

final session = NotifierProvider<Session, bool>(Session.new);

class Counter extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final counter = NotifierProvider<Counter, int>(Counter.new);

/// What a current-user fetch is: autoDispose, async, and counted.
var userFetches = 0;
final user = FutureProvider.autoDispose<String?>((ref) async {
  userFetches++;
  final signedIn = ref.watch(session);
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return signedIn ? 'ann' : null;
});

/// How often the guards below ran (a refresh runs them again).
var runs = 0;

GoRoute guarded(
  String path,
  String site,
  GuardResult Function(Ref ref, Uri uri) guard,
) => GoRoute(
  path: path,
  redirect: (context, state) => refGuard(context, site, (ref) {
    runs++;
    opened++;
    ref.onDispose(() => closed++);
    return guard(ref, state.uri);
  }),
  builder: (_, _) => Text(path.substring(1).toUpperCase()),
);

/// What the generated `mount()` would return: no `refreshListenable` anywhere.
List<RouteBase> routes({
  GuardResult Function(Ref ref, Uri uri)? inbox,
  GuardResult Function(Ref ref, Uri uri)? login,
}) => [
  guarded(
    '/inbox',
    'g1@1',
    inbox ?? (ref, uri) => ref.watch(session) ? null : '/login?from=$uri',
  ),
  guarded(
    '/login',
    'g2@2',
    login ?? (ref, uri) => ref.watch(session) ? '/inbox' : null,
  ),
  GoRoute(path: '/other', builder: (_, _) => const Text('OTHER')),
  GoRoute(path: '/third', builder: (_, _) => const Text('THIRD')),
];

GoRouter router({
  String initial = '/inbox',
  GuardResult Function(Ref ref, Uri uri)? inbox,
  GuardResult Function(Ref ref, Uri uri)? login,
}) {
  final r = GoRouter(
    initialLocation: initial,
    routes: routes(inbox: inbox, login: login),
  );
  addTearDown(r.dispose);
  return r;
}

/// The guard evaluations still open: counted when one runs, and when its provider goes.
var opened = 0;
var closed = 0;
int get open => opened - closed;

void main() {
  setUp(() {
    runs = 0;
    opened = 0;
    closed = 0;
    userFetches = 0;
  });

  group('a sync Ref guard', () {
    testWidgets('moves on sign-out and back on sign-in', (tester) async {
      final c = await pumpRouter(tester, router());
      expect(find.text('INBOX'), findsOneWidget);
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/login?from=/inbox');
      expect(find.text('LOGIN'), findsOneWidget);
      c.read(session.notifier).set(true);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/inbox');
      expect(find.text('INBOX'), findsOneWidget);
    });

    testWidgets('boots with no blank frame, and navigates in one pump', (
      tester,
    ) async {
      final r = router();
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: r)),
      );
      // The very first frame already shows the page: a sync guard adds no frame.
      expect(find.text('INBOX'), findsOneWidget);
      r.go('/other');
      await tester.pump();
      expect(find.text('OTHER'), findsOneWidget);
      r.go('/inbox');
      await tester.pump();
      expect(find.text('INBOX'), findsOneWidget);
    });

    testWidgets('redirects in one pump when the answer is a location', (
      tester,
    ) async {
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      c.read(session.notifier).set(false);
      final r = router(initial: '/other');
      await pumpRouter(tester, r, container: c);
      r.go('/inbox');
      await tester.pump();
      expect(find.text('LOGIN'), findsOneWidget);
    });

    testWidgets('a guard that never watches does not move on a change', (
      tester,
    ) async {
      final c = await pumpRouter(
        tester,
        router(inbox: (ref, uri) => ref.read(session) ? null : '/login'),
      );
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/inbox');
      // ...but the next navigation sees the current state: ref.read is never stale.
    });

    testWidgets('ref.read sees the current value on every navigation', (
      tester,
    ) async {
      final r = router(
        initial: '/other',
        inbox: (ref, uri) => ref.read(session) ? null : '/login',
      );
      final c = await pumpRouter(tester, r);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/inbox');
      r.go('/other');
      await tester.pumpAndSettle();
      c.read(session.notifier).set(false);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/login');
    });
  });

  group('an async Ref guard', () {
    testWidgets('watches an autoDispose provider and moves on sign-out', (
      tester,
    ) async {
      final c = await pumpRouter(
        tester,
        router(
          inbox: (ref, uri) async =>
              await ref.watch(user.future) == null ? '/login?from=$uri' : null,
        ),
      );
      expect(find.text('INBOX'), findsOneWidget);
      final boot = userFetches;
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/login?from=/inbox');
      // Riverpod recomputed the guard once, and the redirect asked again: the
      // provider the guard watches is fetched once for the change, not twice.
      expect(userFetches - boot, 1);
    });

    testWidgets('an unchanged answer asks nothing of the router', (
      tester,
    ) async {
      final r = router(
        inbox: (ref, uri) async {
          ref.watch(counter);
          return null;
        },
      );
      final c = await pumpRouter(tester, r);
      var refreshed = 0;
      r.routeInformationProvider.addListener(() => refreshed++);
      final before = runs;
      for (var i = 0; i < 3; i++) {
        c.read(counter.notifier).bump();
        await tester.pumpAndSettle();
      }
      expect(runs - before, 3, reason: 'Riverpod recomputes the guard');
      expect(refreshed, 0, reason: 'but the answer is the same: no refresh');
      expect(currentLocation(tester), '/inbox');
    });

    testWidgets('the guard of a page left behind stops watching', (
      tester,
    ) async {
      final r = router(
        inbox: (ref, uri) async =>
            await ref.watch(user.future) == null ? '/login' : null,
      );
      final c = await pumpRouter(tester, r);
      expect(open, 1);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(open, 0);
      final before = userFetches;
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/other');
      expect(userFetches, before, reason: 'nothing watches the user any more');
    });

    testWidgets('keeps a Future a Future, and a sync value sync', (
      tester,
    ) async {
      final r = router(initial: '/other');
      await pumpRouter(tester, r);
      final context = tester.element(find.byType(Navigator).first);
      expect(
        refGuard(context, 'x@1', (ref) => null),
        isNot(isA<Future<String?>>()),
      );
      expect(
        refGuard(context, 'x@2', (ref) async => null),
        isA<Future<String?>>(),
      );
      expect(refRedirect(context, (ref) => '/a'), '/a');
    });
  });

  group('the subscription follows the committed location', () {
    testWidgets(
      'push then pop: the guard of the page underneath reacts again',
      (tester) async {
        final r = router();
        final c = await pumpRouter(tester, r);
        unawaited(r.push<void>('/other'));
        await tester.pumpAndSettle();
        r.pop();
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/inbox');
        c.read(session.notifier).set(false);
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/login?from=/inbox');
      },
    );

    testWidgets('a guarded page under a pushed page waits for the pop', (
      tester,
    ) async {
      final r = router();
      final c = await pumpRouter(tester, r);
      unawaited(r.push<void>('/other'));
      await tester.pumpAndSettle();
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/other');
      expect(open, 0, reason: 'the push dropped the subscription');
      r.pop();
      await tester.pumpAndSettle();
      // Popping runs the guard again, and the answer is the new one.
      expect(currentLocation(tester), '/login?from=/inbox');
    });

    testWidgets('go to a page without the guard closes it', (tester) async {
      final r = router();
      await pumpRouter(tester, r);
      expect(open, 1);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(open, 0);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(open, 1);
      r.go('/third');
      await tester.pumpAndSettle();
      expect(open, 0);
    });

    testWidgets('evaluating a site again replaces its subscription', (
      tester,
    ) async {
      final r = router();
      await pumpRouter(tester, r);
      for (var i = 0; i < 4; i++) {
        r.go('/inbox?n=$i');
        await tester.pumpAndSettle();
        expect(open, 1);
      }
    });

    testWidgets('a redirect chain keeps only guards of what it ends on', (
      tester,
    ) async {
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      c.read(session.notifier).set(false);
      await pumpRouter(tester, router(), container: c);
      expect(currentLocation(tester), '/login?from=/inbox');
      // /inbox sent it to /login; both guards ran, and both are held until the next
      // navigation, so signing in moves it back.
      c.read(session.notifier).set(true);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/inbox');
    });
  });

  group('the router the guard is in', () {
    testWidgets('a host GoRouter with no refreshListenable reacts', (
      tester,
    ) async {
      final host = GoRouter(initialLocation: '/inbox', routes: routes());
      addTearDown(host.dispose);
      final c = await pumpRouter(tester, host);
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/login?from=/inbox');
      c.read(session.notifier).set(true);
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/inbox');
    });

    testWidgets('two routers in turn, on one container', (tester) async {
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      for (var i = 0; i < 2; i++) {
        final r = GoRouter(initialLocation: '/inbox', routes: routes());
        await pumpRouter(tester, r, container: c);
        c.read(session.notifier).set(false);
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/login?from=/inbox');
        c.read(session.notifier).set(true);
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/inbox');
        await tester.pumpWidget(const SizedBox());
        r.dispose();
      }
    });

    testWidgets('with no router around it, it is a one-off evaluation', (
      tester,
    ) async {
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      late BuildContext context;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: Builder(
            builder: (cx) {
              context = cx;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        refGuard(context, 'x@1', (ref) {
          opened++;
          ref.onDispose(() => closed++);
          return ref.watch(session) ? 'a' : 'b';
        }),
        'a',
      );
      await tester.pump();
      expect(open, 0);
      expect(
        await refGuard(context, 'x@1', (ref) async {
          opened++;
          ref.onDispose(() => closed++);
          return 'late';
        }),
        'late',
      );
      await tester.pump();
      expect(open, 0);
    });
  });

  group('robustness', () {
    testWidgets('disposing the app closes every subscription, quietly', (
      tester,
    ) async {
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      final r = router();
      await pumpRouter(tester, r, container: c);
      expect(open, 1);
      await tester.pumpWidget(const SizedBox());
      // The container outlives the router: what the guard watches changes, the
      // tree is gone, nothing is refreshed, the subscription goes.
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(open, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an async guard superseded mid-await throws nothing', (
      tester,
    ) async {
      final r = router(
        initial: '/other',
        inbox: (ref, uri) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          // `ref` is used after an await, possibly after the site was replaced.
          return ref.watch(session) ? null : '/login';
        },
      );
      await pumpRouter(tester, r);
      r.go('/inbox');
      await tester.pump(const Duration(milliseconds: 10));
      r.go('/inbox?again');
      await tester.pump(const Duration(milliseconds: 10));
      r.go('/other');
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/other');
      // The evaluations still awaiting are closed only once they have answered.
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      // Back where it was, the router committed nothing, so what the abandoned
      // navigations evaluated is kept until the router commits somewhere (one at
      // most per guard site), and then it goes.
      r.go('/third');
      await tester.pumpAndSettle();
      r.go('/other');
      await tester.pumpAndSettle();
      expect(open, 0);
    });

    testWidgets('a change while an async guard is still answering', (
      tester,
    ) async {
      final r = router(
        initial: '/other',
        inbox: (ref, uri) async {
          final signedIn = ref.watch(session);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return signedIn ? null : '/login';
        },
      );
      final c = await pumpRouter(tester, r);
      r.go('/inbox');
      await tester.pump(const Duration(milliseconds: 20));
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(currentLocation(tester), '/login');
    });

    testWidgets(
      'a guard that throws reaches go_router, and leaves nothing open',
      (tester) async {
        final r = router(
          initial: '/other',
          inbox: (ref, uri) => throw StateError('boom'),
        );
        await pumpRouter(tester, r);
        r.go('/inbox');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNotNull);
        expect(open, 0);
        final ran = runs;
        // The container's default retry would run a throwing provider again later.
        await tester.pump(const Duration(minutes: 1));
        expect(runs, ran, reason: 'no retry timer behind the navigation');
      },
    );

    testWidgets('a guard that throws under the default retry runs once', (
      tester,
    ) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final r = router(
        initial: '/other',
        inbox: (ref, uri) => throw StateError('boom'),
      );
      await pumpRouter(tester, r, container: c);
      r.go('/inbox');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNotNull);
      final ran = runs;
      await tester.pump(const Duration(minutes: 1));
      expect(runs, ran);
      expect(open, 0);
    });

    testWidgets('an async guard that fails reaches go_router and closes', (
      tester,
    ) async {
      final r = router(
        initial: '/other',
        inbox: (ref, uri) async => throw StateError('boom'),
      );
      await pumpRouter(tester, r);
      final errors = <Object>[];
      await runZonedGuarded(() async {
        r.go('/inbox');
        await tester.pumpAndSettle();
      }, (error, _) => errors.add(error));
      expect(errors, hasLength(1));
      expect(open, 0);
    });

    testWidgets('a watched provider failing later keeps the page', (
      tester,
    ) async {
      final fails = NotifierProvider<Session, bool>(Session.new);
      final r = router(
        inbox: (ref, uri) {
          if (ref.watch(fails) == false) throw StateError('later');
          return null;
        },
      );
      final c = await pumpRouter(tester, r);
      c.read(fails.notifier).set(false);
      await tester.pumpAndSettle();
      // The re-evaluation failed: the page stays, and nothing throws.
      expect(currentLocation(tester), '/inbox');
      expect(tester.takeException(), isNull);
    });
  });

  group('refRedirect', () {
    testWidgets('evaluates once and leaves nothing open', (tester) async {
      final r = GoRouter(
        initialLocation: '/old',
        routes: [
          GoRoute(
            path: '/old',
            redirect: (context, state) => refRedirect(context, (ref) {
              runs++;
              return ref.watch(session) ? '/new' : '/other';
            }),
          ),
          GoRoute(path: '/new', builder: (_, _) => const Text('NEW')),
          GoRoute(path: '/other', builder: (_, _) => const Text('OTHER')),
        ],
      );
      addTearDown(r.dispose);
      final c = await pumpRouter(tester, r);
      expect(find.text('NEW'), findsOneWidget);
      expect(runs, 1);
      c.read(session.notifier).set(false);
      await tester.pumpAndSettle();
      expect(runs, 1);
      expect(currentLocation(tester), '/new');
    });
  });
}
