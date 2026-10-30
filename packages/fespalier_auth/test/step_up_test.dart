// Step-up authentication (RFC 9470, since 0.25.0): a 401 with
// `error="insufficient_user_authentication"` makes the user prove who they are again, once, shared
// by every request that asks; the request is sent again once, and a second refusal is the answer.
// Also: the session's authentication time (stored, restored, kept by a renewal) and the
// freshness guards.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final payouts = Uri.parse('https://api.example.com/payouts');

const credentialHeader = 'x-fake-credential';
const stepUpHeader =
    'Bearer realm="api", error="insufficient_user_authentication", '
    'acr_values="gold", max_age=60';

TransportRequest get(Uri uri) => TransportRequest(method: 'GET', uri: uri);

/// An API that answers 200 to the credentials in [accepted], a plain 401 (a renewal) to those in
/// [expired], and a step-up 401 to anything else.
final class StepUpApi {
  final Set<String> accepted = {};
  final Set<String> expired = {};

  late final FakeTransport transport = FakeTransport((request, _) {
    final id = request.headers[credentialHeader]?.split('#').first;
    if (accepted.contains(id)) return fakeResponse(200, body: 'paid');
    if (expired.contains(id)) return fakeResponse(401);
    return fakeResponse(401, headers: {'www-authenticate': stepUpHeader});
  });

  /// The credential header of each request that arrived, in order.
  List<String?> get ids => [
    for (final r in transport.requests) r.lowerHeaders[credentialHeader],
  ];
}

void main() {
  late FakeAuthBackend backend;
  late StepUpApi server;
  late ProviderContainer container;
  late SpyStore store;

  void setUpSession({AuthUser user = ada}) {
    backend = FakeAuthBackend(user: user);
    server = StepUpApi();
    store = SpyStore([]);
    container = containerFor(
      signedInAs: user,
      backend: backend,
      apiOrigins: [api],
      transport: server.transport,
      store: store,
    );
  }

  SessionTransport transport() =>
      SessionTransport(server.transport, container.read(authorizer));

  AuthSessionNotifier notifier() => container.read(authSession.notifier);

  group('the transport', () {
    test(
      'a step-up refusal: one re-proof with its challenge, one retry',
      () async {
        setUpSession();
        server.accepted.add('fake-1');
        final response = await transport().send(get(payouts));
        expect(response.statusCode, 200);
        expect(utf8.decode(await response.bytes()), 'paid');
        expect(server.ids, ['fake-0#1', 'fake-1#2']);
        expect(backend.stepUps, 1);
        expect(backend.stepUpChallenges, [
          const StepUpChallenge(
            acrValues: ['gold'],
            maxAge: Duration(minutes: 1),
          ),
        ]);
        expect(backend.renewals, 0);
        expect(
          server.transport.requests[1].request.attributes[transportReplayKey],
          isTrue,
        );
        final state = container.read(authSession) as SignedIn;
        expect((state.session.credential as FakeCredential).id, 'fake-1');
        expect(state.session.authenticatedAt, isNotNull);
        expect(store.log, ['write'], reason: 'the stepped-up session is kept');
      },
    );

    test('a second refusal is the answer: no second prompt, no loop', () async {
      setUpSession();
      final response = await transport().send(get(payouts));
      expect(response.statusCode, 401);
      expect(server.ids, ['fake-0#1', 'fake-1#2']);
      expect(backend.stepUps, 1);
      expect(container.read(authSession), isA<SignedIn>());
    });

    test('concurrent refusals share one re-proof', () async {
      setUpSession();
      server.accepted.add('fake-1');
      backend.gate = Completer<void>();
      final sending = [
        for (var i = 0; i < 3; i++) transport().send(get(payouts)),
      ];
      // Let every first send come back refused and wait for the one step-up.
      await pumpEventQueue();
      expect(backend.stepUps, 1);
      backend.gate!.complete();
      final responses = await Future.wait(sending);
      expect(responses.map((r) => r.statusCode), [200, 200, 200]);
      expect(backend.stepUps, 1);
      expect(server.ids.where((id) => id!.startsWith('fake-1#')), hasLength(3));
    });

    test(
      'a refusal that comes back after another request stepped up retries with '
      'the new credential, without asking again',
      () async {
        setUpSession();
        server.accepted.add('fake-1');
        await transport().send(get(payouts));
        expect(backend.stepUps, 1);
        // A request authorized with fake-0 before the step-up, refused after it.
        final late = FakeTransport.script([
          fakeResponse(401, headers: {'www-authenticate': stepUpHeader}),
          fakeResponse(200),
        ]);
        final auth = container.read(authorizer);
        final attempt = await auth.authorize(get(payouts));
        await notifier().stepUp(const StepUpChallenge());
        expect(backend.stepUps, 2);
        final again = await auth.retry(attempt, await late.send(get(payouts)));
        expect(again, isTrue);
        expect(backend.stepUps, 2, reason: 'no third prompt');
      },
    );

    test(
      'the user cancels: the 401 stands, the session stays, nothing is stored',
      () async {
        setUpSession();
        final before = container.read(authSession);
        backend.stepUpError = const AuthCancelled();
        final response = await transport().send(get(payouts));
        expect(response.statusCode, 401);
        expect(server.ids, ['fake-0#1']);
        expect(container.read(authSession), before);
        expect(store.log, isEmpty);
        expect(backend.signOuts + backend.discards, 0);
      },
    );

    test(
      'the provider refuses the step-up: the 401 stands, still signed in',
      () async {
        setUpSession();
        backend.stepUpError = const AuthRejected('access_denied');
        final response = await transport().send(get(payouts));
        expect(response.statusCode, 401);
        expect(container.read(authSession), isA<SignedIn>());
        // The request is not refused for good: a later send may step up again.
        backend.stepUpError = null;
        server.accepted.add('fake-1');
        expect((await transport().send(get(payouts))).statusCode, 200);
      },
    );

    test(
      'a step-up that could not ask is an AuthUnavailable, session kept',
      () async {
        setUpSession();
        backend.stepUpError = Exception('offline');
        await expectLater(
          transport().send(get(payouts)),
          throwsA(isA<AuthUnavailable>()),
        );
        expect(container.read(authSession), isA<SignedIn>());
      },
    );

    test(
      'a step-up answered for another user is refused: the session is not taken',
      () async {
        setUpSession();
        backend.stepUpUser = bob;
        server.accepted.add('fake-1');
        final response = await transport().send(get(payouts));
        expect(response.statusCode, 401);
        expect(container.read(authUser), ada);
        expect(store.log, isEmpty);
        await expectLater(
          notifier().stepUp(const StepUpChallenge()),
          throwsA(
            isA<AuthRejected>().having(
              (e) => e.error,
              'error',
              'step_up_user_mismatch',
            ),
          ),
        );
      },
    );

    test(
      'a request marked stepUpAttribute: false never asks the user',
      () async {
        setUpSession();
        final quiet = get(payouts).copyWith(
          attributes: const <String, Object?>{
            Authorizer.stepUpAttribute: false,
          },
        );
        final response = await transport().send(quiet);
        expect(response.statusCode, 401);
        expect(backend.stepUps, 0);
        expect(server.ids, ['fake-0#1']);
      },
    );

    test('one step-up per logical request: a retrier above that sends it again '
        'with the same memo gets the refusal, not a second prompt', () async {
      setUpSession();
      final memo = TransportMemo();
      TransportRequest again() => get(
        payouts,
      ).copyWith(attributes: <String, Object?>{TransportMemo.key: memo});
      expect((await transport().send(again())).statusCode, 401);
      expect(backend.stepUps, 1);
      expect((await transport().send(again())).statusCode, 401);
      expect(backend.stepUps, 1);
      // Another request is another request.
      expect((await transport().send(get(payouts))).statusCode, 401);
      expect(backend.stepUps, 2);
    });

    test('a request may renew once and step up once', () async {
      setUpSession();
      server.expired.add('fake-0');
      server.accepted.add('fake-2');
      final response = await transport().send(get(payouts));
      expect(response.statusCode, 200);
      expect(server.ids, ['fake-0#1', 'fake-1#2', 'fake-2#3']);
      expect(backend.renewals, 1);
      expect(backend.stepUps, 1);
    });

    test(
      'a backend that cannot step up: the UnsupportedError reaches the caller',
      () async {
        final server = StepUpApi();
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(
                backend: _NoStepUpBackend(),
                transport: server.transport,
                store: MemoryTokenStore(),
                apiOrigins: [api],
              ),
            ),
            authInitialState.overrideWithValue(SignedIn(fakeSession(ada))),
          ],
        );
        addTearDown(container.dispose);
        final session = SessionTransport(
          server.transport,
          container.read(authorizer),
        );
        await expectLater(
          session.send(get(payouts)),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );
  });

  group('the authentication time', () {
    final time = TestTime();

    test('a sign-in without one gets the time of the sign-in', () async {
      await time.run(() async {
        final backend = FakeAuthBackend(user: ada);
        final container = containerFor(backend: backend);
        final session = await container
            .read(authSession.notifier)
            .signIn(const TestSignIn());
        expect(session.authenticatedAt, time.now);
        expect(session.authenticatedAt!.isUtc, isTrue);
      });
    });

    test("the backend's own time wins (an ID token's auth_time)", () async {
      final backend = FakeAuthBackend(user: ada)
        ..authTime = DateTime.utc(2026, 2, 1);
      final container = containerFor(backend: backend);
      final session = await container
          .read(authSession.notifier)
          .signIn(const TestSignIn());
      expect(session.authenticatedAt, DateTime.utc(2026, 2, 1));
    });

    test('adopting a session without one stamps it', () async {
      await time.run(() async {
        final container = containerFor(backend: FakeAuthBackend(user: ada));
        await container.read(authSession.notifier).adopt(fakeSession(bob));
        expect(
          container.read(authSession.notifier).session!.authenticatedAt,
          time.now,
        );
      });
    });

    test('a renewal keeps it; a step-up moves it', () async {
      await time.run(() async {
        final backend = FakeAuthBackend(user: ada);
        final container = containerFor(backend: backend);
        final notifier = container.read(authSession.notifier);
        final signedInAt = time.now;
        await notifier.signIn(const TestSignIn());
        time.elapse(const Duration(hours: 1));
        await notifier.credential(forceRenew: true);
        expect(backend.renewals, 1);
        expect(notifier.session!.authenticatedAt, signedInAt);
        time.elapse(const Duration(hours: 1));
        final stepped = await notifier.stepUp(const StepUpChallenge());
        expect(stepped.authenticatedAt, time.now);
        expect(notifier.session, stepped);
      });
    });

    test(
      'a renewal waits for a step-up in flight, and takes its credential',
      () async {
        setUpSession();
        backend.gate = Completer<void>();
        final stepping = notifier().stepUp(const StepUpChallenge());
        await pumpEventQueue();
        final renewed = notifier().credential(
          rejected:
              (container.read(authSession) as SignedIn).session.credential,
        );
        backend.gate!.complete();
        await stepping;
        expect(((await renewed) as FakeCredential).id, 'fake-1');
        expect(backend.renewals, 0);
      },
    );

    test('stored with the session, and read back', () {
      final session = fakeSession(
        ada,
        authenticatedAt: DateTime.utc(2026, 3, 1, 12, 30),
      );
      final json = session.toJson();
      expect(json['authenticatedAt'], '2026-03-01T12:30:00.000Z');
      expect(
        AuthSession.fromJson(
          jsonDecode(jsonEncode(json)) as Map<String, Object?>,
          FakeCredential.fromJson,
        ),
        session,
      );
    });

    test(
      'a session stored before 0.25.0 (no authenticatedAt) still restores, with none',
      () {
        final old = fakeSession(ada).toJson();
        expect(old.containsKey('authenticatedAt'), isFalse);
        final result =
            restoreAuth(
                  AuthConfig(
                    backend: FakeAuthBackend(),
                    transport: noTransport,
                    store: MemoryTokenStore(jsonEncode(old)),
                  ),
                )
                as List<Override>;
        final container = ProviderContainer(overrides: result);
        addTearDown(container.dispose);
        final state = container.read(authSession);
        expect(state, isA<SignedIn>());
        expect((state as SignedIn).session.authenticatedAt, isNull);
      },
    );

    test(
      'a stored authenticatedAt that is not a date is a FormatException',
      () {
        final json = fakeSession(ada).toJson()
          ..['authenticatedAt'] = 'yesterday';
        expect(
          () => AuthSession.fromJson(json, FakeCredential.fromJson),
          throwsFormatException,
        );
      },
    );

    test('authenticatedWithin: unknown and future times are not fresh', () {
      final now = DateTime.utc(2026, 3, 1, 12);
      AuthSession at(DateTime? t) => fakeSession(ada, authenticatedAt: t);
      const five = Duration(minutes: 5);
      expect(at(null).authenticatedWithin(five, now), isFalse);
      expect(at(now).authenticatedWithin(five, now), isTrue);
      expect(at(now.subtract(five)).authenticatedWithin(five, now), isTrue);
      expect(
        at(
          now.subtract(five + const Duration(seconds: 1)),
        ).authenticatedWithin(five, now),
        isFalse,
      );
      expect(
        at(now.add(const Duration(seconds: 1))).authenticatedWithin(five, now),
        isFalse,
      );
    });

    test('the step-up is a step_up span, with no identity in it', () async {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(rec);
      addTearDown(() => FespalierTelemetry.install(null));
      setUpSession();
      await notifier().stepUp(const StepUpChallenge(acrValues: ['gold']));
      backend.stepUpError = const AuthCancelled();
      await expectLater(
        notifier().stepUp(const StepUpChallenge()),
        throwsA(isA<AuthCancelled>()),
      );
      expect(rec.log, [
        '#1 start auth step_up backend=fake scheme=fake',
        '#1 end auth ok async',
        '#2 start auth step_up backend=fake scheme=fake',
        '#2 end auth cancelled async',
      ]);
    });
  });

  group('requireFreshAuth and redirectIfFreshAuth', () {
    const maxAge = Duration(minutes: 5);

    GoRouter router({String initial = '/payouts'}) => GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(path: '/', builder: (_, _) => const Text('page /')),
        GoRoute(
          path: '/sign-in',
          builder: (_, _) => const Text('page /sign-in'),
        ),
        GoRoute(
          path: '/reauth',
          redirect: (context, state) => refGuard(
            context,
            'reauth',
            (ref) => redirectIfFreshAuth(
              ref,
              maxAge: maxAge,
              from: state.uri.queryParameters['from'],
            ),
          ),
          builder: (_, _) => const Text('page /reauth'),
        ),
        GoRoute(
          path: '/payouts',
          redirect: (context, state) => refGuard(
            context,
            'payouts',
            (ref) => requireFreshAuth(
              ref,
              state.uri,
              maxAge: maxAge,
              signIn: (from) => _Location('/sign-in', from),
              reauthenticate: (from) => _Location('/reauth', from),
            ),
          ),
          builder: (_, _) => const Text('page /payouts'),
        ),
      ],
    );

    testWidgets('a recent sign-in opens the route', (tester) async {
      await pumpRouter(
        tester,
        router(),
        overrides: fakeAuth(signedInAs: ada, authenticatedAt: clock.now()),
      );
      expect(currentLocation(tester), '/payouts');
    });

    testWidgets('signed out: sign-in first', (tester) async {
      await pumpRouter(tester, router(), overrides: fakeAuth());
      expect(currentLocation(tester), '/sign-in?from=%2Fpayouts');
    });

    testWidgets('an unknown authentication time is too old', (tester) async {
      await pumpRouter(tester, router(), overrides: fakeAuth(signedInAs: ada));
      expect(currentLocation(tester), '/reauth?from=%2Fpayouts');
    });

    testWidgets(
      'too old: the re-proof page, and a step-up there sends the user back',
      (tester) async {
        final backend = FakeAuthBackend(user: ada);
        final container = await pumpRouter(
          tester,
          router(),
          overrides: fakeAuth(
            signedInAs: ada,
            backend: backend,
            authenticatedAt: clock.now().subtract(
              maxAge + const Duration(seconds: 1),
            ),
          ),
        );
        expect(currentLocation(tester), '/reauth?from=%2Fpayouts');
        expect(find.text('page /reauth'), findsOneWidget);
        await container
            .read(authSession.notifier)
            .stepUp(const StepUpChallenge(maxAge: maxAge));
        await tester.pumpAndSettle();
        expect(currentLocation(tester), '/payouts');
        expect(backend.stepUps, 1);
      },
    );

    testWidgets('the age is read when the route opens: time moves on, the '
        'next navigation asks', (tester) async {
      await pumpRouter(
        tester,
        router(initial: '/'),
        overrides: fakeAuth(signedInAs: ada, authenticatedAt: clock.now()),
      );
      final go = GoRouter.of(tester.element(find.text('page /')));
      go.go('/payouts');
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/payouts');
      go.go('/');
      await tester.pumpAndSettle();
      await tester.pump(maxAge + const Duration(minutes: 1));
      go.go('/payouts');
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/reauth?from=%2Fpayouts');
    });

    testWidgets('redirectIfFreshAuth refuses to leave the app', (tester) async {
      await pumpRouter(
        tester,
        router(
          initial:
              '/reauth?from=${Uri.encodeQueryComponent('//evil.example.com')}',
        ),
        overrides: fakeAuth(signedInAs: ada, authenticatedAt: clock.now()),
      );
      expect(currentLocation(tester), '/');
    });
  });
}

final class _Location extends TypedLocation {
  const _Location(this.path, this.from);

  final String path;
  final String from;

  @override
  String get location => '$path?from=${Uri.encodeQueryComponent(from)}';
}

/// A backend with no step-up, whose authenticator (the fake's) still says StepUp.
final class _NoStepUpBackend extends StubBackend {
  _NoStepUpBackend();
}
