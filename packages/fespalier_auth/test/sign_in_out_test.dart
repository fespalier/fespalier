// signIn, adopt and signOut: what they store, what they publish, in which order, and what a
// failure leaves behind.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const password = PasswordSignIn(username: 'ada', password: 'ada');

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
      final session = await notifier.signIn(password);
      expect(session.user, ada);
      expect(container.read(authSession), SignedIn(session));
      expect(log, ['write']);
      final saved = AuthSession.fromJson(
        jsonDecode(store.value!) as Map<String, Object?>,
      );
      expect(saved, session);
      expect(order, ['state SignedIn']);
      expect(backend.signIns, 1);
      expect(backend.requests.single, same(password));
    });

    test(
      'a wrong password: FieldErrors is rethrown, and the state is unchanged',
      () async {
        signedOut();
        backend.signInError = const FieldErrors({'password': 'Wrong password'});
        await expectLater(
          notifier.signIn(password),
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
        // The error was for that attempt only.
        await notifier.signIn(password);
        expect(container.read(authSession), isA<SignedIn>());
      },
    );

    test(
      'a cancelled sign-in is rethrown, and the state is unchanged',
      () async {
        signedOut();
        backend.signInError = const AuthCancelled();
        await expectLater(
          notifier.signIn(password),
          throwsA(isA<AuthCancelled>()),
        );
        expect(container.read(authSession), const SignedOut());
      },
    );

    test(
      'a refusal is rethrown, and a signed-in user stays signed in',
      () async {
        signedIn();
        backend.signInError = const AuthRejected();
        await expectLater(
          notifier.signIn(password),
          throwsA(isA<AuthRejected>()),
        );
        expect(container.read(authSession), isA<SignedIn>());
      },
    );

    test('signing in again replaces the session', () async {
      signedOut();
      await notifier.signIn(password);
      final first = notifier.session!.tokens.accessToken;
      await notifier.signIn(password);
      expect(notifier.session!.tokens.accessToken, isNot(first));
      expect(log, ['write', 'write']);
    });

    test(
      'a sign-in overtaken by a newer one throws NotSignedIn and stores nothing',
      () async {
        signedOut();
        final gate = backend.gate = Completer<void>();
        final pending = notifier.signIn(password);
        // Another sign-in starts, and the first is overtaken.
        backend.gate = null;
        final second = await notifier.signIn(password);
        gate.complete();
        await expectLater(pending, throwsA(isA<NotSignedIn>()));
        expect((container.read(authSession) as SignedIn).session, second);
        expect(log, ['write']);
      },
    );

    test('the state stays signed out until the backend answers', () async {
      signedOut();
      final gate = backend.gate = Completer<void>();
      final pending = notifier.signIn(password);
      expect(container.read(authSession), const SignedOut());
      gate.complete();
      await pending;
      expect(container.read(authSession), isA<SignedIn>());
    });
  });

  group('adopt', () {
    test('signs in with a session the app made', () async {
      signedOut();
      final session = fakeSession(bob);
      await notifier.adopt(session);
      expect(container.read(authSession), SignedIn(session));
      expect(log, ['write']);
      expect(backend.signIns, 0);
    });

    test(
      'a session of another backend is an ArgumentError with the text of M10',
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
      },
    );
  });

  group('signOut', () {
    test(
      'is synchronous to SignedOut(user), then clears the store, signs out the backend, resets the proof',
      () async {
        final proof = FakeProof();
        backend = FakeAuthBackend(user: ada, proof: proof);
        log = [];
        store = SpyStore(log);
        container = containerFor(
          signedInAs: ada,
          backend: backend,
          store: store,
        );
        notifier = container.read(authSession.notifier);
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
        expect(proof.resets, 1);
      },
    );

    test(
      'the backend failing to sign out is swallowed: the user is out anyway',
      () async {
        final failing = _FailingSignOut();
        final c = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(backend: failing, store: SpyStore([])),
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
      },
    );

    test('signed out already: a no-op', () async {
      signedOut();
      await notifier.signOut();
      expect(container.read(authSession), const SignedOut());
      expect(log, isEmpty);
      expect(backend.signOuts, 0);
    });

    test('after a sign-out the user can sign in again', () async {
      signedIn();
      await notifier.signOut();
      await notifier.signIn(password);
      expect(container.read(authSession), isA<SignedIn>());
    });
  });
}

final class _FailingSignOut extends AuthBackend {
  int attempts = 0;

  @override
  String get name => 'failing';

  @override
  Future<AuthSession> signIn(SignInRequest request) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> refresh(AuthSession session) =>
      throw UnimplementedError();

  @override
  Future<void> signOut(AuthSession session) async {
    attempts++;
    throw StateError('server down');
  }
}
