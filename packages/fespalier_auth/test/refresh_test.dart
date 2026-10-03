// tokens(): synchronous while the access token is good, and one shared refresh otherwise.
// Time is a clock the test moves; nothing waits for real time.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const lifetime = Duration(minutes: 5);

void main() {
  late TestTime time;
  late FakeAuthBackend backend;
  late SpyStore store;
  late List<String> storeLog;
  late ProviderContainer container;
  late AuthSessionNotifier notifier;

  /// Runs a test body on the test clock, with a signed-in container.
  void scenario(String name, Future<void> Function() body) {
    test(name, () {
      time = TestTime();
      return time.run(() async {
        backend = FakeAuthBackend(tokenLifetime: lifetime);
        storeLog = [];
        store = SpyStore(storeLog);
        container = containerFor(
          signedInAs: ada,
          backend: backend,
          store: store,
          tokenLifetime: lifetime,
        );
        notifier = container.read(authSession.notifier);
        await body();
      });
    });
  }

  String access() =>
      (container.read(authSession) as SignedIn).session.tokens.accessToken;

  scenario(
    'a good access token is returned synchronously: not a Future',
    () async {
      final tokens = notifier.tokens();
      expect(tokens, isA<AuthTokens>());
      expect(tokens, isNot(isA<Future<Object?>>()));
      expect((tokens as AuthTokens).accessToken, 'fake-access-0');
      expect(backend.refreshes, 0);
    },
  );

  scenario('inside the leeway the token already counts as expired', () async {
    time.elapse(lifetime - const Duration(seconds: 31));
    expect(notifier.tokens(), isA<AuthTokens>());
    time.elapse(const Duration(seconds: 2));
    expect(notifier.tokens(), isA<Future<AuthTokens>>());
    await (notifier.tokens() as Future<AuthTokens>);
  });

  scenario(
    'three concurrent calls on an expired token share one refresh',
    () async {
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final a = notifier.tokens();
      final b = notifier.tokens();
      final c = notifier.tokens();
      expect([a, b, c], everyElement(isA<Future<AuthTokens>>()));
      expect(backend.refreshes, 1);
      // Still the old session while the refresh is out.
      expect(access(), 'fake-access-0');
      gate.complete();
      final results = await Future.wait([
        a as Future<AuthTokens>,
        b as Future<AuthTokens>,
        c as Future<AuthTokens>,
      ]);
      expect(backend.refreshes, 1);
      expect(results.map((t) => t.accessToken).toSet(), {'fake-access-1'});
      expect(access(), 'fake-access-1');
      // The next call is a good token again, and synchronous.
      expect(notifier.tokens(), isA<AuthTokens>());
    },
  );

  scenario(
    'a refresh does not publish a new SignedOut or flicker the guards',
    () async {
      final signedIn = <bool>[];
      final users = <AuthUser?>[];
      container.listen(isSignedIn, (_, next) => signedIn.add(next));
      container.listen(authUser, (_, next) => users.add(next));
      final states = <SessionState>[];
      container.listen(authSession, (_, next) => states.add(next));
      time.elapse(const Duration(minutes: 6));
      await (notifier.tokens() as Future<AuthTokens>);
      expect(states, hasLength(1));
      expect(states.single, isA<SignedIn>());
      // `==` filters: nobody watching isSignedIn or authUser hears of a token swap.
      expect(signedIn, isEmpty);
      expect(users, isEmpty);
    },
  );

  scenario('the store has the new tokens before the state does', () async {
    final order = <String>[];
    container.listen(authSession, (_, next) {
      order.add('state ${(next as SignedIn).session.tokens.accessToken}');
    });
    storeLog.clear();
    time.elapse(const Duration(minutes: 6));
    await (notifier.tokens() as Future<AuthTokens>);
    expect(storeLog, ['write']);
    expect(order, ['state fake-access-1']);
    expect(store.value, contains('fake-access-1'));
    expect(store.value, contains('fake-refresh-1'));
  });

  scenario(
    'rejected: an access token someone already replaced is not refreshed again',
    () async {
      time.elapse(const Duration(minutes: 6));
      await (notifier.tokens() as Future<AuthTokens>);
      expect(backend.refreshes, 1);
      // A request that carried fake-access-0 gets its 401 now.
      final again = notifier.tokens(rejected: 'fake-access-0');
      expect(
        again,
        isA<AuthTokens>(),
        reason: 'synchronous: no second refresh',
      );
      expect((again as AuthTokens).accessToken, 'fake-access-1');
      expect(backend.refreshes, 1);
    },
  );

  scenario(
    'rejected: the token in use is refreshed even though it looks good',
    () async {
      final result = notifier.tokens(rejected: 'fake-access-0');
      expect(result, isA<Future<AuthTokens>>());
      expect((await result).accessToken, 'fake-access-1');
      expect(backend.refreshes, 1);
    },
  );

  scenario('two 401s to the same token refresh once', () async {
    final gate = backend.gate = Completer<void>();
    final a = notifier.tokens(rejected: 'fake-access-0') as Future<AuthTokens>;
    final b = notifier.tokens(rejected: 'fake-access-0') as Future<AuthTokens>;
    gate.complete();
    await Future.wait([a, b]);
    expect(backend.refreshes, 1);
  });

  scenario('forceRefresh refreshes a good token', () async {
    final result = notifier.tokens(forceRefresh: true);
    expect(result, isA<Future<AuthTokens>>());
    expect((await result).accessToken, 'fake-access-1');
  });

  scenario(
    'a refresh the server refuses signs out with reason expired',
    () async {
      backend.refreshError = const AuthRejected(
        'invalid_grant',
        'Token is not active',
      );
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final a = notifier.tokens() as Future<AuthTokens>;
      final b = notifier.tokens() as Future<AuthTokens>;
      final failures = [
        expectLater(a, throwsA(isA<AuthRejected>())),
        expectLater(b, throwsA(isA<AuthRejected>())),
      ];
      gate.complete();
      await Future.wait(failures);
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(store.value, isNull, reason: 'the store is cleared');
      expect(backend.refreshes, 1);
      expect(() => notifier.tokens(), throwsA(isA<NotSignedIn>()));
    },
  );

  scenario(
    'a refresh that could not run keeps the session, and the next call tries again',
    () async {
      backend.refreshError = Exception('offline');
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final a = notifier.tokens() as Future<AuthTokens>;
      final b = notifier.tokens() as Future<AuthTokens>;
      final failures = [
        expectLater(a, throwsA(isA<AuthUnavailable>())),
        expectLater(b, throwsA(isA<AuthUnavailable>())),
      ];
      gate.complete();
      await Future.wait(failures);
      expect(container.read(authSession), isA<SignedIn>());
      expect(access(), 'fake-access-0');
      expect(backend.refreshes, 1);

      backend.refreshError = null;
      final next = await (notifier.tokens() as Future<AuthTokens>);
      expect(next.accessToken, 'fake-access-1');
      expect(backend.refreshes, 2);
    },
  );

  scenario(
    "an AuthUnavailable the backend threw is passed on as it is",
    () async {
      final error = AuthUnavailable(Exception('x'));
      backend.refreshError = error;
      time.elapse(const Duration(minutes: 6));
      await expectLater(
        notifier.tokens() as Future<AuthTokens>,
        throwsA(same(error)),
      );
    },
  );

  scenario(
    'an unavailable server is a ClientException that names no host',
    () async {
      backend.refreshError = Exception('connection refused');
      time.elapse(const Duration(minutes: 6));
      try {
        await (notifier.tokens() as Future<AuthTokens>);
        fail('expected a failure');
      } on AuthUnavailable catch (e) {
        expect(
          e.message,
          "fespalier_auth: couldn't refresh the session: Exception: connection refused",
        );
        expect(e.uri, isNull);
      }
    },
  );

  scenario(
    'signing out during a refresh: the waiters get NotSignedIn, and it stays signed out',
    () async {
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final waiting = notifier.tokens() as Future<AuthTokens>;
      final failure = expectLater(waiting, throwsA(isA<NotSignedIn>()));
      final out = notifier.signOut();
      gate.complete();
      await failure;
      await out;
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      expect(store.value, isNull, reason: 'the late tokens were not stored');
      expect(storeLog.where((e) => e == 'write'), isEmpty);
    },
  );

  scenario(
    'a refresh that finishes after a new sign-in is thrown away',
    () async {
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final waiting = notifier.tokens() as Future<AuthTokens>;
      final failure = expectLater(waiting, throwsA(isA<NotSignedIn>()));
      await notifier.signOut();
      // signIn waits for the gate too: complete it, the refresh was first in line.
      final signIn = notifier.signIn(
        const PasswordSignIn(username: 'bob', password: 'x'),
      );
      gate.complete();
      await failure;
      await signIn;
      expect(container.read(authSession), isA<SignedIn>());
      expect(backend.refreshes, 1);
    },
  );

  scenario(
    'a signed-out app has no tokens: NotSignedIn, as a StateError',
    () async {
      await notifier.signOut();
      expect(() => notifier.tokens(), throwsA(isA<NotSignedIn>()));
      expect(() => notifier.tokens(), throwsStateError);
      try {
        notifier.tokens();
      } on StateError catch (e) {
        expect('$e', 'Bad state: fespalier_auth: not signed in');
      }
    },
  );

  scenario(
    'a session with no expiry is sent until a server says 401',
    () async {
      final open = containerFor(signedInAs: ada, backend: FakeAuthBackend());
      final n = open.read(authSession.notifier);
      time.elapse(const Duration(days: 30));
      expect(n.tokens(), isA<AuthTokens>());
    },
  );

  scenario(
    'a refresh that fails before its first await still clears the single flight',
    () async {
      final broken = _ThrowsAtOnce();
      final c = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(backend: broken, store: MemoryTokenStore()),
          ),
          authInitialState.overrideWithValue(
            SignedIn(fakeSession(ada, lifetime: lifetime)),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(authSession.notifier);
      time.elapse(const Duration(minutes: 6));
      await expectLater(
        n.tokens() as Future<AuthTokens>,
        throwsA(isA<AuthUnavailable>()),
      );
      broken.fail = false;
      expect(
        (await (n.tokens() as Future<AuthTokens>)).accessToken,
        'fake-access-1',
      );
    },
  );

  test(
    'a failing store is reported, and the session still works in memory',
    () async {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
      final t = TestTime();
      await t.run(() async {
        final b = FakeAuthBackend(tokenLifetime: lifetime);
        final c = containerFor(
          signedInAs: ada,
          backend: b,
          store: _WriteFails(),
          tokenLifetime: lifetime,
        );
        final n = c.read(authSession.notifier);
        t.elapse(const Duration(minutes: 6));
        final tokens = await (n.tokens() as Future<AuthTokens>);
        expect(tokens.accessToken, 'fake-access-1');
        expect(c.read(authSession), isA<SignedIn>());
      });
      expect(errors, hasLength(1));
      expect(errors.single.context.toString(), 'while storing the session');
    },
  );
}

/// A backend whose refresh throws before it awaits anything (a synchronous failure).
final class _ThrowsAtOnce extends AuthBackend {
  _ThrowsAtOnce();

  bool fail = true;

  @override
  String get name => 'fake';

  @override
  Future<AuthSession> signIn(SignInRequest request) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> refresh(AuthSession session) {
    if (fail) throw Exception('no network at all');
    return Future.value(
      session.copyWith(
        tokens: const AuthTokens(
          accessToken: 'fake-access-1',
          refreshToken: 'r',
        ),
      ),
    );
  }

  @override
  Future<void> signOut(AuthSession session) async {}
}

final class _WriteFails implements TokenStore {
  @override
  String? read() => null;

  @override
  void write(String value) => throw StateError('disk full');

  @override
  void delete() {}
}
