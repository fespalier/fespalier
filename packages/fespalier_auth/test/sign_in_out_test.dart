// signIn, adopt and signOut: what they store, what they publish, in which order, and what a
// failure leaves behind.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const request = TestSignIn();

void main() {
  late FakeAuthBackend backend;
  late List<String> log;
  late SpyStore store;
  late ProviderContainer container;
  late AuthSessionNotifier notifier;

  void signedOut({FakeAuthBackend? use}) {
    backend = use ?? FakeAuthBackend(user: ada);
    log = [];
    store = SpyStore(log);
    container = containerFor(backend: backend, store: store);
    notifier = container.read(authSession.notifier);
  }

  void signedIn() {
    backend = FakeAuthBackend(user: ada);
    log = [];
    store = SpyStore(log);
    container = containerFor(signedInAs: ada, backend: backend, store: store);
    notifier = container.read(authSession.notifier);
  }

  group('signIn', () {
    test('stores the session, then sets SignedIn', () async {
      signedOut();
      final order = <String>[];
      container.listen(
        authSession,
        (_, next) => order.add('state ${next.runtimeType}'),
      );
      final session = await notifier.signIn(request);
      expect(session.user, ada);
      expect(session.backend, 'fake');
      expect(container.read(authSession), SignedIn(session));
      expect(log, ['write']);
      final saved = AuthSession.fromJson(
        jsonDecode(store.value!) as Map<String, Object?>,
        FakeCredential.fromJson,
      );
      expect(saved, session);
      expect(order, ['state SignedIn']);
      expect(backend.signIns, 1);
      expect(backend.requests.single, same(request));
    });

    test('the session is also the notifier\'s session', () async {
      signedOut();
      expect(notifier.session, isNull);
      final session = await notifier.signIn(request);
      expect(notifier.session, session);
    });

    test(
      'a wrong password: FieldErrors is rethrown, and the state is unchanged',
      () async {
        signedOut();
        backend.signInError = const FieldErrors({'password': 'Wrong password'});
        await expectLater(
          notifier.signIn(request),
          throwsA(
            isA<FieldErrors>().having(
              (e) => e.fields['password'],
              'password',
              'Wrong password',
            ),
          ),
        );
        expect(container.read(authSession), const SignedOut());
        expect(store.value, isNull);
        expect(log, isEmpty);
        // The error was for that attempt only.
        await notifier.signIn(request);
        expect(container.read(authSession), isA<SignedIn>());
      },
    );

    test(
      'a cancelled sign-in is rethrown, and the state is unchanged',
      () async {
        signedOut();
        backend.signInError = const AuthCancelled();
        await expectLater(
          notifier.signIn(request),
          throwsA(isA<AuthCancelled>()),
        );
        expect(container.read(authSession), const SignedOut());
        expect(log, isEmpty);
      },
    );

    test(
      'a refusal is rethrown, and a signed-in user stays signed in with the same session',
      () async {
        signedIn();
        final before = notifier.session;
        backend.signInError = const AuthRejected();
        await expectLater(
          notifier.signIn(request),
          throwsA(isA<AuthRejected>()),
        );
        expect(container.read(authSession), isA<SignedIn>());
        expect(notifier.session, before);
        expect(log, isEmpty);
      },
    );

    test(
      'any other error is rethrown too, and the state is unchanged',
      () async {
        signedOut();
        backend.signInError = StateError('the network is down');
        await expectLater(notifier.signIn(request), throwsStateError);
        expect(container.read(authSession), const SignedOut());
        expect(log, isEmpty);
      },
    );

    test('signing in again replaces the session', () async {
      signedOut();
      await notifier.signIn(request);
      final first = notifier.session!.credential;
      await notifier.signIn(request);
      expect(notifier.session!.credential, isNot(first));
      expect(log, ['write', 'write']);
    });

    test('a sign-in as another user replaces the user', () async {
      signedOut();
      await notifier.signIn(request);
      backend.user = bob;
      await notifier.signIn(request);
      expect(container.read(authUser), bob);
      expect(container.read(authUserId), 'bob-id');
    });

    test(
      'a sign-in overtaken by a newer one throws NotSignedIn and stores nothing',
      () async {
        signedOut();
        final gate = backend.gate = Completer<void>();
        final pending = notifier.signIn(request);
        // Another sign-in starts, and the first is overtaken.
        backend.gate = null;
        final second = await notifier.signIn(request);
        gate.complete();
        await expectLater(pending, throwsA(isA<NotSignedIn>()));
        expect((container.read(authSession) as SignedIn).session, second);
        expect(log, ['write']);
      },
    );

    test('the state stays signed out until the backend answers', () async {
      signedOut();
      final gate = backend.gate = Completer<void>();
      final pending = notifier.signIn(request);
      expect(container.read(authSession), const SignedOut());
      gate.complete();
      await pending;
      expect(container.read(authSession), isA<SignedIn>());
    });

    test('a sign-in answered after a sign-out is thrown away', () async {
      signedIn();
      final gate = backend.gate = Completer<void>();
      final pending = notifier.signIn(request);
      final failure = expectLater(pending, throwsA(isA<NotSignedIn>()));
      await notifier.signOut();
      gate.complete();
      await failure;
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      expect(log, ['delete'], reason: 'the late session was not stored');
    });

    test(
      'a store that fails to write is reported, and the session works',
      () async {
        final errors = <FlutterErrorDetails>[];
        final old = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = old);
        backend = FakeAuthBackend(user: ada);
        container = containerFor(backend: backend, store: _WriteFails());
        notifier = container.read(authSession.notifier);
        await notifier.signIn(request);
        expect(container.read(authSession), isA<SignedIn>());
        expect(errors, hasLength(1));
        expect(errors.single.context.toString(), 'while storing the session');
      },
    );
  });

  group('adopt', () {
    test('signs in with a session the app made', () async {
      signedOut();
      // With its authentication time: one without gets the time of the call (step_up_test).
      final session = fakeSession(bob, authenticatedAt: DateTime.utc(2026));
      await notifier.adopt(session);
      expect(container.read(authSession), SignedIn(session));
      expect(log, ['write']);
      expect(backend.signIns, 0);
    });

    test(
      'a session of another backend is an ArgumentError that names both',
      () async {
        signedOut();
        final foreign = fakeSession(bob, backend: 'firebase');
        await expectLater(
          notifier.adopt(foreign),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'fespalier_auth: this session comes from the backend "firebase", but the configured backend is "fake"',
            ),
          ),
        );
        expect(container.read(authSession), const SignedOut());
        expect(log, isEmpty);
      },
    );
  });

  group('signOut', () {
    test(
      'is synchronous to SignedOut(user), then clears the store, signs out the backend, discards what is bound to the session',
      () async {
        signedIn();
        store.value = 'kept';
        final states = <SessionState>[];
        container.listen(authSession, (_, next) => states.add(next));

        final done = notifier.signOut();
        // Before the first await: guards that watch the session move in this frame.
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
        expect(states, [const SignedOut(reason: SignOutReason.user)]);
        expect(
          backend.signOuts,
          0,
          reason: 'the backend comes after the local sign-out',
        );
        await done;
        expect(log, ['delete']);
        expect(store.value, isNull);
        expect(backend.signOuts, 1);
        expect(backend.discards, 1);
      },
    );

    test(
      'the backend failing to sign out is swallowed, and it still discards: the user is out anyway',
      () async {
        final failing = _FailingSignOut();
        final c = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(
                backend: failing,
                transport: noTransport,
                store: SpyStore([]),
              ),
            ),
            authInitialState.overrideWithValue(
              SignedIn(fakeSession(ada, backend: 'failing')),
            ),
          ],
        );
        addTearDown(c.dispose);
        await c.read(authSession.notifier).signOut();
        expect(
          c.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
        expect(failing.attempts, 1);
        expect(
          failing.discards,
          1,
          reason: 'discard runs even when signOut threw',
        );
      },
    );

    test('a discard that throws is swallowed too', () async {
      final failing = _FailingSignOut(discardFails: true);
      final c = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: failing,
              transport: noTransport,
              store: SpyStore([]),
            ),
          ),
          authInitialState.overrideWithValue(
            SignedIn(fakeSession(ada, backend: 'failing')),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(authSession.notifier).signOut();
      expect(c.read(authSession), const SignedOut(reason: SignOutReason.user));
      expect(failing.discards, 1);
    });

    test('a store that fails to delete does not stop the backend', () async {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
      backend = FakeAuthBackend(user: ada);
      container = containerFor(
        signedInAs: ada,
        backend: backend,
        store: _DeleteFails(),
      );
      notifier = container.read(authSession.notifier);
      await notifier.signOut();
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      expect(backend.signOuts, 1);
      expect(backend.discards, 1);
      expect(
        errors.single.context.toString(),
        'while clearing the stored session',
      );
    });

    test('signed out already: a no-op', () async {
      signedOut();
      await notifier.signOut();
      expect(container.read(authSession), const SignedOut());
      expect(log, isEmpty);
      expect(backend.signOuts, 0);
      expect(backend.discards, 0);
    });

    test('after a sign-out the user can sign in again', () async {
      signedIn();
      await notifier.signOut();
      await notifier.signIn(request);
      expect(container.read(authSession), isA<SignedIn>());
    });

    test('a second sign-out while the first runs does nothing more', () async {
      signedIn();
      final first = notifier.signOut();
      final second = notifier.signOut();
      await Future.wait([first, second]);
      expect(backend.signOuts, 1);
      expect(backend.discards, 1);
    });
  });
}

final class _FailingSignOut extends StubBackend {
  _FailingSignOut({this.discardFails = false}) : super('failing');

  final bool discardFails;
  int attempts = 0;
  int discards = 0;

  @override
  Future<void> signOut(AuthSession session) async {
    attempts++;
    throw StateError('server down');
  }

  @override
  Future<void> discard(AuthSession session) async {
    discards++;
    if (discardFails) throw StateError('keystore locked');
  }
}

final class _WriteFails implements TokenStore {
  @override
  String? read() => null;

  @override
  void write(String value) => throw StateError('disk full');

  @override
  void delete() {}
}

final class _DeleteFails implements TokenStore {
  @override
  String? read() => null;

  @override
  void write(String value) {}

  @override
  void delete() => throw StateError('cannot delete');
}
