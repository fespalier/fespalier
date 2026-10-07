// flagGuard on a real GoRouter, through fespalier's refGuard (what a generated `redirect:` calls), under
// pumpRouter: the flag decides the route, follows a change, and is let go of with the guard.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:fespalier_flags/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const labs = BoolFlag('labs');

/// A second reason to refuse a route, for the guards that compose.
final signedIn = NotifierProvider<_SignedIn, bool>(_SignedIn.new);

class _SignedIn extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

GoRoute page(
  String path,
  String label, {
  GuardResult Function(Ref ref)? guard,
}) => GoRoute(
  path: path,
  redirect: guard == null
      ? null
      : (context, state) => refGuard(context, '$path@0', guard),
  builder: (context, state) => Text(label),
);

/// `/` and `/other` are open; the guards of the others are the tests'.
GoRouter routerAt(String location, List<GoRoute> guarded) => GoRouter(
  initialLocation: location,
  routes: [page('/', 'Home'), page('/other', 'Other'), ...guarded],
);

void main() {
  testWidgets('with the flag on, the route is there', (tester) async {
    final fake = FakeFlags({'labs': true});
    final router = routerAt('/labs', [
      page('/labs', 'Labs', guard: (ref) => flagGuard(ref, labs, orElse: '/')),
    ]);
    await pumpRouter(
      tester,
      router,
      overrides: [flagSource.overrideWithValue(fake)],
    );
    expect(currentLocation(tester), '/labs');
    expect(find.text('Labs'), findsOneWidget);
  });

  testWidgets(
    'with the flag off at a cold deep link, the first frame is orElse',
    (tester) async {
      final router = routerAt('/labs', [
        page(
          '/labs',
          'Labs',
          guard: (ref) => flagGuard(ref, labs, orElse: '/'),
        ),
      ]);
      await pumpRouter(
        tester,
        router,
        overrides: [flagSource.overrideWithValue(FakeFlags())],
        settle: false,
      );
      // One frame, no settling: the flag was there before the router decided.
      expect(currentLocation(tester), '/');
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Labs'), findsNothing);
    },
  );

  testWidgets('without an override the flag is its fallback: off', (
    tester,
  ) async {
    final router = routerAt('/labs', [
      page('/labs', 'Labs', guard: (ref) => flagGuard(ref, labs, orElse: '/')),
    ]);
    await pumpRouter(tester, router);
    expect(currentLocation(tester), '/');
  });

  testWidgets(
    'turning the flag off on the route takes the app off it after one pump',
    (tester) async {
      final fake = FakeFlags({'labs': true});
      final router = routerAt('/labs', [
        page(
          '/labs',
          'Labs',
          guard: (ref) => flagGuard(ref, labs, orElse: '/'),
        ),
      ]);
      await pumpRouter(
        tester,
        router,
        overrides: [flagSource.overrideWithValue(fake)],
      );
      expect(find.text('Labs'), findsOneWidget);
      fake.set('labs', false);
      await tester.pump();
      expect(currentLocation(tester), '/');
      // go_router 17.0.0, the only one Flutter 3.32 resolves, builds the page a frame later.
      if (onFlutterFloor) await tester.pump();
      expect(find.text('Home'), findsOneWidget);
    },
  );

  testWidgets('a refused navigation is let through once the flag is on', (
    tester,
  ) async {
    final fake = FakeFlags();
    final router = routerAt('/', [
      page('/labs', 'Labs', guard: (ref) => flagGuard(ref, labs, orElse: '/')),
    ]);
    await pumpRouter(
      tester,
      router,
      overrides: [flagSource.overrideWithValue(fake)],
    );
    router.go('/labs');
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
    fake.set('labs', true);
    router.go('/labs');
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/labs');
  });

  group('the flag is let go of with the guard', () {
    // fespalier keeps a guard that redirected subscribed until the next navigation commits (docs/guards.md, "Guards"), so
    // the flag, which the guard watches, is listened to for one navigation longer than the page it gated was
    // there. These tests pin that: if fespalier changes the lifetime of a redirecting guard, they say so.
    testWidgets('on the page: one subscription, gone at the next navigation', (
      tester,
    ) async {
      final fake = FakeFlags({'labs': true});
      final router = routerAt('/labs', [
        page(
          '/labs',
          'Labs',
          guard: (ref) => flagGuard(ref, labs, orElse: '/'),
        ),
      ]);
      await pumpRouter(
        tester,
        router,
        overrides: [flagSource.overrideWithValue(fake)],
      );
      expect(fake.listenerCount, 1);
      router.go('/other');
      await tester.pumpAndSettle();
      expect(fake.listenerCount, 0);
    });

    testWidgets(
      'a guard that redirected stays subscribed until the next navigation',
      (tester) async {
        final fake = FakeFlags(); // off
        final router = routerAt('/labs', [
          page(
            '/labs',
            'Labs',
            guard: (ref) => flagGuard(ref, labs, orElse: '/'),
          ),
        ]);
        await pumpRouter(
          tester,
          router,
          overrides: [flagSource.overrideWithValue(fake)],
        );
        expect(currentLocation(tester), '/');
        // The page was never shown, and the flag is still listened to.
        expect(
          fake.listenerCount,
          1,
          reason: 'a redirecting guard stays until the next commit',
        );
        router.go('/other');
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/other');
        expect(fake.listenerCount, 0);
      },
    );

    testWidgets(
      'while it stays, a change turns the flag on and the router does not move',
      (tester) async {
        final fake = FakeFlags(); // off: the cold deep link was sent to '/'
        final router = routerAt('/labs', [
          page(
            '/labs',
            'Labs',
            guard: (ref) => flagGuard(ref, labs, orElse: '/'),
          ),
        ]);
        await pumpRouter(
          tester,
          router,
          overrides: [flagSource.overrideWithValue(fake)],
        );
        fake.set('labs', true);
        await tester.pump();
        // The guard's answer changed, so the router asked again: but the location it asks about is '/', which has
        // no guard, so it stays.
        expect(currentLocation(tester), '/');
      },
    );
  });

  testWidgets(
    'whenOff inverts: a route that is only there while the flag is off',
    (tester) async {
      final fake = FakeFlags();
      final router = routerAt('/legacy', [
        page(
          '/legacy',
          'Legacy',
          guard: (ref) => flagGuard(ref, labs, whenOff: true, orElse: '/other'),
        ),
      ]);
      await pumpRouter(
        tester,
        router,
        overrides: [flagSource.overrideWithValue(fake)],
      );
      expect(currentLocation(tester), '/legacy');
      fake.set('labs', true);
      await tester.pump();
      expect(currentLocation(tester), '/other');
    },
  );

  group('follow: false', () {
    testWidgets(
      'reads once per navigation: the page stays, the next navigation applies the change',
      (tester) async {
        final fake = FakeFlags({'labs': true});
        final router = routerAt('/flow', [
          page(
            '/flow',
            'Flow',
            guard: (ref) => flagGuard(ref, labs, orElse: '/', follow: false),
          ),
        ]);
        await pumpRouter(
          tester,
          router,
          overrides: [flagSource.overrideWithValue(fake)],
        );
        expect(currentLocation(tester), '/flow');
        fake.set('labs', false);
        await tester.pump();
        expect(
          currentLocation(tester),
          '/flow',
          reason: 'the page is not taken away mid-flow',
        );
        expect(find.text('Flow'), findsOneWidget);
        router.go('/other');
        await tester.pumpAndSettle();
        router.go('/flow');
        await tester.pumpAndSettle();
        expect(
          currentLocation(tester),
          '/',
          reason: 'a new navigation reads the flag again',
        );
      },
    );

    testWidgets('listens to nothing once the guard has answered', (
      tester,
    ) async {
      final fake = FakeFlags({'labs': true});
      final router = routerAt('/flow', [
        page(
          '/flow',
          'Flow',
          guard: (ref) => flagGuard(ref, labs, orElse: '/', follow: false),
        ),
      ]);
      await pumpRouter(
        tester,
        router,
        overrides: [flagSource.overrideWithValue(fake)],
      );
      await tester.pump();
      expect(fake.listenerCount, 0);
    });
  });

  group('composes', () {
    GoRouter composed(String location) => routerAt(location, [
      page(
        '/members',
        'Members',
        guard: (ref) =>
            flagGuard(ref, labs, orElse: '/') ??
            (ref.watch(signedIn) ? null : '/other'),
      ),
    ]);

    testWidgets('the flag first: off, the other guard is not asked', (
      tester,
    ) async {
      final fake = FakeFlags();
      await pumpRouter(
        tester,
        composed('/members'),
        overrides: [flagSource.overrideWithValue(fake)],
      );
      expect(currentLocation(tester), '/');
    });

    testWidgets('on, the other guard decides', (tester) async {
      final fake = FakeFlags({'labs': true});
      final container = await pumpRouter(
        tester,
        composed('/members'),
        overrides: [flagSource.overrideWithValue(fake)],
      );
      expect(currentLocation(tester), '/other');
      container.read(signedIn.notifier).set(true);
      final router = GoRouter.of(tester.element(find.byType(Navigator).first));
      router.go('/members');
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/members');
      // Both are watched: the other guard's change moves the router too.
      container.read(signedIn.notifier).set(false);
      await tester.pump();
      expect(currentLocation(tester), '/other');
    });

    testWidgets(
      'turning the flag off takes the user off a page the other guard let in',
      (tester) async {
        final fake = FakeFlags({'labs': true});
        final container = await pumpRouter(
          tester,
          composed('/'),
          overrides: [flagSource.overrideWithValue(fake)],
        );
        container.read(signedIn.notifier).set(true);
        GoRouter.of(
          tester.element(find.byType(Navigator).first),
        ).go('/members');
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/members');
        fake.set('labs', false);
        await tester.pump();
        expect(currentLocation(tester), '/');
      },
    );
  });
}
