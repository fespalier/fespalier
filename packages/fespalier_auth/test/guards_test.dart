// The guard helpers on a router built the way a generated app.g.dart builds one (refGuard), and
// on their own.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final class SignInRoute extends TypedLocation {
  const SignInRoute({this.from});

  final String? from;

  @override
  String get location => from == null
      ? '/sign-in'
      : '/sign-in?from=${Uri.encodeQueryComponent(from!)}';
}

final class ForbiddenRoute extends TypedLocation {
  const ForbiddenRoute();

  @override
  String get location => '/forbidden';
}

/// How often each guard ran.
final Map<String, int> runs = {};

GoRoute guarded(String path, GuardResult Function(Ref ref, Uri uri) guard) =>
    GoRoute(
      path: path,
      redirect: (context, state) => refGuard(context, 'g$path', (ref) {
        runs.update(path, (n) => n + 1, ifAbsent: () => 1);
        return guard(ref, state.uri);
      }),
      builder: (_, _) => Text('page $path'),
    );

GoRouter router({String initial = '/orders'}) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(path: '/', builder: (_, _) => const Text('page /')),
    GoRoute(
      path: '/sign-in',
      redirect: (context, state) => refGuard(context, 'sign-in', (ref) {
        runs.update('/sign-in', (n) => n + 1, ifAbsent: () => 1);
        return redirectIfSignedIn(ref, from: state.uri.queryParameters['from']);
      }),
      builder: (_, _) => const Text('page /sign-in'),
    ),
    guarded(
      '/orders',
      (ref, uri) =>
          requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from)),
    ),
    guarded(
      '/orders/1',
      (ref, uri) =>
          requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from)),
    ),
    guarded(
      '/admin',
      (ref, uri) => requireRole(
        ref,
        uri,
        'admin',
        signIn: (from) => SignInRoute(from: from),
        forbidden: const ForbiddenRoute(),
      ),
    ),
    guarded(
      '/team',
      (ref, uri) => requireUser(
        ref,
        uri,
        (user) => user.email?.endsWith('@example.com') ?? false,
        signIn: (from) => SignInRoute(from: from),
        forbidden: const ForbiddenRoute(),
      ),
    ),
    GoRoute(
      path: '/forbidden',
      builder: (_, _) => const Text('page /forbidden'),
    ),
  ],
);

void main() {
  setUp(runs.clear);

  group('on a router', () {
    testWidgets(
      'signed out, a guarded route goes to sign-in with where it was going',
      (tester) async {
        await pumpRouter(tester, router(), overrides: fakeAuth());
        expect(currentLocation(tester), '/sign-in?from=%2Forders');
        expect(find.text('page /sign-in'), findsOneWidget);
      },
    );

    testWidgets('signed in, the route shows', (tester) async {
      await pumpRouter(tester, router(), overrides: fakeAuth(signedInAs: ada));
      expect(currentLocation(tester), '/orders');
      expect(find.text('page /orders'), findsOneWidget);
    });

    testWidgets('requireRole: an admin gets in, anybody else is forbidden', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        router(initial: '/admin'),
        overrides: fakeAuth(signedInAs: ada),
      );
      expect(currentLocation(tester), '/admin');

      await pumpRouter(
        tester,
        router(initial: '/admin'),
        overrides: fakeAuth(signedInAs: bob),
      );
      expect(currentLocation(tester), '/forbidden');
    });

    testWidgets('requireRole signed out: sign-in first, not forbidden', (
      tester,
    ) async {
      await pumpRouter(
        tester,
        router(initial: '/admin'),
        overrides: fakeAuth(),
      );
      expect(currentLocation(tester), '/sign-in?from=%2Fadmin');
    });

    testWidgets('requireUser: the test decides', (tester) async {
      await pumpRouter(
        tester,
        router(initial: '/team'),
        overrides: fakeAuth(signedInAs: ada),
      );
      expect(currentLocation(tester), '/team');
      await pumpRouter(
        tester,
        router(initial: '/team'),
        overrides: fakeAuth(
          signedInAs: const AuthUser(id: 'x', email: 'x@elsewhere.org'),
        ),
      );
      expect(currentLocation(tester), '/forbidden');
    });

    testWidgets(
      'signing out on a page moves the user to sign-in, with that page as from',
      (tester) async {
        final container = await pumpRouter(
          tester,
          router(initial: '/orders/1'),
          overrides: fakeAuth(signedInAs: ada),
        );
        expect(currentLocation(tester), '/orders/1');
        unawaited(container.read(authSession.notifier).signOut());
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/sign-in?from=%2Forders%2F1');
      },
    );

    testWidgets(
      'signing in on the sign-in page sends the user back: no navigation code',
      (tester) async {
        final container = await pumpRouter(
          tester,
          router(initial: '/orders/1'),
          overrides: fakeAuth(),
        );
        expect(currentLocation(tester), '/sign-in?from=%2Forders%2F1');
        await container
            .read(authSession.notifier)
            .signIn(const PasswordSignIn(username: 'ada', password: 'ada'));
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/orders/1');
        expect(find.text('page /orders/1'), findsOneWidget);
      },
    );

    testWidgets(
      'redirectIfSignedIn never leaves the app: returnTo refuses another host',
      (tester) async {
        for (final from in [
          '//evil.example.com',
          'https://evil.example.com',
          r'/\evil',
        ]) {
          await pumpRouter(
            tester,
            router(initial: '/sign-in?from=${Uri.encodeQueryComponent(from)}'),
            overrides: fakeAuth(signedInAs: ada),
          );
          expect(currentLocation(tester), '/', reason: from);
        }
      },
    );

    testWidgets('a token refresh does not run any guard again', (tester) async {
      final backend = FakeAuthBackend(
        tokenLifetime: const Duration(minutes: 5),
      );
      final container = await pumpRouter(
        tester,
        router(initial: '/admin'),
        overrides: fakeAuth(signedInAs: ada, backend: backend),
      );
      expect(currentLocation(tester), '/admin');
      final before = Map<String, int>.of(runs);
      expect(before['/admin'], 1);
      await tester.pump(const Duration(minutes: 6));
      final tokens = container.read(authSession.notifier).tokens();
      expect(tokens, isA<Future<AuthTokens>>());
      await tokens;
      await tester.pumpAndSettle();
      expect(backend.refreshes, 1);
      expect(
        runs,
        before,
        reason: 'isSignedIn and the role answer did not change',
      );
      expect(currentLocation(tester), '/admin');
    });

    testWidgets('a role gained or lost does run the guard again', (
      tester,
    ) async {
      final backend = FakeAuthBackend(
        tokenLifetime: const Duration(minutes: 5),
      );
      final container = await pumpRouter(
        tester,
        router(initial: '/admin'),
        overrides: fakeAuth(signedInAs: ada, backend: backend),
      );
      // The server took the role away: the refresh brings a user without it.
      final notifier = container.read(authSession.notifier);
      final current = notifier.session!;
      await notifier.adopt(
        current.copyWith(
          user: const AuthUser(id: 'ada-id', name: 'Ada'),
        ),
      );
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/forbidden');
    });

    testWidgets(
      'a cold start with restoreAuth: the guarded page is the first thing on screen',
      (tester) async {
        final session = fakeSession(ada);
        final overrides = restoreAuth(
          AuthConfig(
            backend: FakeAuthBackend(),
            store: MemoryTokenStore(jsonEncode(session.toJson())),
          ),
        );
        expect(overrides, isA<List<Override>>());
        await pumpRouter(
          tester,
          router(initial: '/orders/1'),
          overrides: overrides as List<Override>,
          settle: false,
        );
        // No pump of the event loop beyond the first frame: no redirect to sign-in, no blank frame.
        expect(find.text('page /orders/1'), findsOneWidget);
        expect(runs['/sign-in'], isNull);
      },
    );

    testWidgets('without restoreAuth the guard waits for the stored session', (
      tester,
    ) async {
      final gate = Completer<void>();
      final session = fakeSession(ada);
      final container = await pumpRouter(
        tester,
        router(initial: '/orders/1'),
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: FakeAuthBackend(),
              store: GatedStore(gate, jsonEncode(session.toJson())),
            ),
          ),
        ],
        settle: false,
      );
      await tester.pump();
      expect(find.text('page /orders/1'), findsNothing);
      expect(find.text('page /sign-in'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/orders/1');
      expect(container.read(authSession), isA<SignedIn>());
    });
  });

  group('on their own', () {
    SignInRoute signIn(String from) => SignInRoute(from: from);
    Provider<GuardResult> probe(GuardResult Function(Ref ref) guard) =>
        Provider<GuardResult>(guard);

    test('requireSignedIn answers synchronously when the state is known', () {
      final signedOutContainer = containerFor();
      final out = signedOutContainer.read(
        probe(
          (ref) =>
              requireSignedIn(ref, Uri.parse('/orders?page=2'), signIn: signIn),
        ),
      );
      expect(out, isNot(isA<Future<Object?>>()));
      expect(out, '/sign-in?from=%2Forders%3Fpage%3D2');

      final signedInContainer = containerFor(signedInAs: ada);
      final inside = signedInContainer.read(
        probe(
          (ref) => requireSignedIn(ref, Uri.parse('/orders'), signIn: signIn),
        ),
      );
      expect(inside, isNull);
    });

    test('requireRole and requireUser answer synchronously too', () {
      final c = containerFor(signedInAs: bob);
      expect(
        c.read(
          probe(
            (ref) => requireRole(
              ref,
              Uri.parse('/a'),
              'admin',
              signIn: signIn,
              forbidden: const ForbiddenRoute(),
            ),
          ),
        ),
        '/forbidden',
      );
      expect(
        c.read(
          probe(
            (ref) => requireUser(
              ref,
              Uri.parse('/a'),
              (u) => u.id == 'bob-id',
              signIn: signIn,
              forbidden: const ForbiddenRoute(),
            ),
          ),
        ),
        isNull,
      );
    });

    test(
      'while the stored session is read the answer is a Future, which waits',
      () async {
        final gate = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(
                backend: FakeAuthBackend(),
                store: GatedStore(gate, jsonEncode(fakeSession(ada).toJson())),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final plain = container.read(
          probe((ref) => requireSignedIn(ref, Uri.parse('/x'), signIn: signIn)),
        );
        expect(plain, isA<Future<String?>>());
        final role = container.read(
          probe(
            (ref) => requireRole(
              ref,
              Uri.parse('/x'),
              'admin',
              signIn: signIn,
              forbidden: const ForbiddenRoute(),
            ),
          ),
        );
        expect(role, isA<Future<String?>>());
        final staff = container.read(
          probe(
            (ref) => requireRole(
              ref,
              Uri.parse('/x'),
              'staff',
              signIn: signIn,
              forbidden: const ForbiddenRoute(),
            ),
          ),
        );
        gate.complete();
        expect(await (plain as Future<String?>), isNull);
        expect(await (role as Future<String?>), isNull);
        expect(await (staff as Future<String?>), '/forbidden');
      },
    );

    test(
      'while restoring a session that turns out to be none: sign-in',
      () async {
        final gate = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(backend: FakeAuthBackend(), store: GatedStore(gate)),
            ),
          ],
        );
        addTearDown(container.dispose);
        final answer =
            container.read(
                  probe(
                    (ref) =>
                        requireSignedIn(ref, Uri.parse('/x'), signIn: signIn),
                  ),
                )
                as Future<String?>;
        gate.complete();
        expect(await answer, '/sign-in?from=%2Fx');
      },
    );

    test('redirectIfSignedIn: the fallback, and the default /', () {
      final c = containerFor(signedInAs: ada);
      expect(c.read(probe((ref) => redirectIfSignedIn(ref))), '/');
      expect(
        c.read(probe((ref) => redirectIfSignedIn(ref, from: '/orders'))),
        '/orders',
      );
      expect(
        c.read(probe((ref) => redirectIfSignedIn(ref, fallback: '/home'))),
        '/home',
      );
      expect(
        containerFor().read(
          probe((ref) => redirectIfSignedIn(ref, from: '/orders')),
        ),
        isNull,
      );
    });
  });
}
