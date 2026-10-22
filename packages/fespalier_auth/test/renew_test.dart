// credential(): synchronous while the credential is good, and one shared renewal otherwise.
// Time is a clock the test moves; nothing waits for real time.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const lifetime = Duration(minutes: 5);
const renewAhead = Duration(seconds: 30);

void main() {
  late TestTime time;
  late FakeAuthBackend backend;
  late SpyStore store;
  late List<String> storeLog;
  late ProviderContainer container;
  late AuthSessionNotifier notifier;

  /// Runs a test body on the test clock, with a signed-in container whose credentials live
  /// [lifetime] and are renewed [ahead] before they expire.
  void scenario(
    String name,
    Future<void> Function() body, {
    Duration ahead = Duration.zero,
  }) {
    test(name, () {
      time = TestTime();
      return time.run(() async {
        backend = FakeAuthBackend(
          credentialLifetime: lifetime,
          renewAhead: ahead,
        );
        storeLog = [];
        store = SpyStore(storeLog);
        container = containerFor(
          signedInAs: ada,
          backend: backend,
          store: store,
          credentialLifetime: lifetime,
        );
        notifier = container.read(authSession.notifier);
        await body();
      });
    });
  }

  String held() =>
      ((container.read(authSession) as SignedIn).session.credential
              as FakeCredential)
          .id;

  Future<SessionCredential> later(FutureOr<SessionCredential> value) {
    expect(value, isA<Future<SessionCredential>>());
    return value as Future<SessionCredential>;
  }

  String idOf(SessionCredential credential) =>
      (credential as FakeCredential).id;

  scenario(
    'a good credential is returned synchronously: not a Future',
    () async {
      final credential = notifier.credential();
      expect(credential, isA<FakeCredential>());
      expect(credential, isNot(isA<Future<Object?>>()));
      expect(idOf(credential as SessionCredential), 'fake-0');
      expect(backend.renewals, 0);
    },
  );

  scenario(
    'with a renewAhead of zero the credential is good until the instant it expires',
    () async {
      time.elapse(lifetime - const Duration(seconds: 1));
      expect(notifier.credential(), isA<FakeCredential>());
      time.elapse(const Duration(seconds: 1));
      expect(notifier.credential(), isA<Future<SessionCredential>>());
      await later(notifier.credential());
    },
  );

  scenario(
    'inside the renewAhead the credential already counts as expiring',
    () async {
      time.elapse(lifetime - const Duration(seconds: 31));
      expect(notifier.credential(), isA<FakeCredential>());
      expect(backend.renewals, 0);
      time.elapse(const Duration(seconds: 2));
      final renewed = await later(notifier.credential());
      expect(idOf(renewed), 'fake-1');
      expect(backend.renewals, 1);
    },
    ahead: renewAhead,
  );

  scenario(
    'a renewAhead longer than the lifetime renews every time until the new one is good',
    () async {
      // 5 minutes of life, 10 minutes ahead: every credential is born expiring.
      backend = FakeAuthBackend(
        credentialLifetime: lifetime,
        renewAhead: const Duration(minutes: 10),
      );
      container = containerFor(
        signedInAs: ada,
        backend: backend,
        credentialLifetime: lifetime,
      );
      notifier = container.read(authSession.notifier);
      expect(notifier.credential(), isA<Future<SessionCredential>>());
      await later(notifier.credential());
    },
  );

  scenario(
    'three concurrent calls on an expired credential share one renewal',
    () async {
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final a = later(notifier.credential());
      final b = later(notifier.credential());
      final c = later(notifier.credential());
      await pumpEventQueue();
      expect(backend.renewals, 1);
      // Still the old session while the renewal is out.
      expect(held(), 'fake-0');
      gate.complete();
      final results = await Future.wait([a, b, c]);
      expect(backend.renewals, 1);
      expect(results.map(idOf).toSet(), {'fake-1'});
      expect(held(), 'fake-1');
      // The next call is a good credential again, and synchronous.
      expect(notifier.credential(), isA<FakeCredential>());
    },
  );

  scenario(
    'a renewal does not publish a new SignedOut or flicker the guards',
    () async {
      final signedIn = <bool>[];
      final users = <AuthUser?>[];
      container.listen(isSignedIn, (_, next) => signedIn.add(next));
      container.listen(authUser, (_, next) => users.add(next));
      final ids = <String?>[];
      container.listen(authUserId, (_, next) => ids.add(next));
      final states = <SessionState>[];
      container.listen(authSession, (_, next) => states.add(next));
      time.elapse(const Duration(minutes: 6));
      await later(notifier.credential());
      expect(states, hasLength(1));
      expect(states.single, isA<SignedIn>());
      // `==` filters: nobody watching isSignedIn or authUser hears of a credential swap.
      expect(signedIn, isEmpty);
      expect(users, isEmpty);
      expect(ids, isEmpty);
    },
  );

  scenario('the store has the new credential before the state does', () async {
    final order = <String>[];
    container.listen(authSession, (_, next) {
      order.add('state ${storeLog.length}');
    });
    storeLog.clear();
    time.elapse(const Duration(minutes: 6));
    await later(notifier.credential());
    expect(storeLog, ['write']);
    expect(order, ['state 1'], reason: 'the write was logged before the state');
    expect(store.value, contains('fake-1'));
  });

  scenario(
    'rejected: a credential someone already replaced is not renewed again',
    () async {
      time.elapse(const Duration(minutes: 6));
      final first = await later(notifier.credential());
      expect(backend.renewals, 1);
      // A request that carried the credential before the renewal gets its 401 now.
      final again = notifier.credential(
        rejected: FakeCredential(
          id: 'fake-0',
          expiresAt: DateTime.utc(2026, 3, 1, 12, 5),
        ),
      );
      expect(idOf(first), 'fake-1');
      expect(
        again,
        isA<FakeCredential>(),
        reason: 'synchronous: no second renewal',
      );
      expect(idOf(again as SessionCredential), 'fake-1');
      expect(backend.renewals, 1);
    },
  );

  scenario(
    'rejected: the credential in use is renewed even though it looks good',
    () async {
      final inUse = notifier.credential() as SessionCredential;
      final result = notifier.credential(rejected: inUse);
      expect(result, isA<Future<SessionCredential>>());
      expect(idOf(await (result as Future<SessionCredential>)), 'fake-1');
      expect(backend.renewals, 1);
    },
  );

  scenario('two 401s to the same credential renew once', () async {
    final inUse = notifier.credential() as SessionCredential;
    final gate = backend.gate = Completer<void>();
    final a = later(notifier.credential(rejected: inUse));
    final b = later(notifier.credential(rejected: inUse));
    gate.complete();
    final results = await Future.wait([a, b]);
    expect(backend.renewals, 1);
    expect(results.map(idOf).toSet(), {'fake-1'});
  });

  scenario('forceRenew renews a good credential', () async {
    final result = notifier.credential(forceRenew: true);
    expect(result, isA<Future<SessionCredential>>());
    expect(idOf(await (result as Future<SessionCredential>)), 'fake-1');
    expect(backend.renewals, 1);
  });

  scenario('forceRenew joins a renewal already running', () async {
    final gate = backend.gate = Completer<void>();
    final a = later(notifier.credential(forceRenew: true));
    final b = later(notifier.credential(forceRenew: true));
    gate.complete();
    await Future.wait([a, b]);
    expect(backend.renewals, 1);
  });

  scenario(
    'the hint reaches backend.renew, and null when there is none',
    () async {
      const hint = Object();
      await later(notifier.credential(forceRenew: true, hint: hint));
      await later(notifier.credential(forceRenew: true));
      expect(backend.hints, hasLength(2));
      expect(backend.hints.first, same(hint));
      expect(backend.hints.last, isNull);
    },
  );

  scenario(
    'while a renewal is running the first caller\'s hint stands',
    () async {
      final gate = backend.gate = Completer<void>();
      final a = later(notifier.credential(forceRenew: true, hint: 'first'));
      final b = later(notifier.credential(forceRenew: true, hint: 'second'));
      gate.complete();
      await Future.wait([a, b]);
      expect(backend.renewals, 1);
      expect(backend.hints, ['first']);
    },
  );

  scenario(
    'a renewal the server refuses signs out with reason expired, forgets the credential and fails every waiter',
    () async {
      backend.renewError = const AuthRejected(
        'invalid_grant',
        'Token is not active',
      );
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final a = later(notifier.credential());
      final b = later(notifier.credential());
      final failures = [
        expectLater(
          a,
          throwsA(
            isA<AuthRejected>()
                .having((e) => e.error, 'error', 'invalid_grant')
                .having(
                  (e) => e.description,
                  'description',
                  'Token is not active',
                ),
          ),
        ),
        expectLater(b, throwsA(isA<AuthRejected>())),
      ];
      gate.complete();
      await Future.wait(failures);
      await pumpEventQueue();
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(store.value, isNull, reason: 'the store is cleared');
      expect(backend.renewals, 1);
      expect(
        backend.discards,
        1,
        reason: 'what was bound to the session is forgotten',
      );
      expect(
        backend.signOuts,
        0,
        reason: 'no call to the server: it ended the session',
      );
      expect(() => notifier.credential(), throwsA(isA<NotSignedIn>()));
    },
  );

  scenario(
    'AuthEnded(revoked): SignedOut(revoked), the store cleared, and the waiters get an AuthRejected with what the server said',
    () async {
      backend.renewError = const AuthEnded(
        SignOutReason.revoked,
        error: 'device_revoked',
        description: 'This device was removed',
      );
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final a = later(notifier.credential());
      final b = later(notifier.credential());
      final failures = [
        expectLater(
          a,
          throwsA(
            isA<AuthRejected>()
                .having((e) => e.error, 'error', 'device_revoked')
                .having(
                  (e) => e.description,
                  'description',
                  'This device was removed',
                ),
          ),
        ),
        expectLater(b, throwsA(isA<AuthRejected>())),
      ];
      gate.complete();
      await Future.wait(failures);
      await pumpEventQueue();
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.revoked),
      );
      expect(store.value, isNull);
      expect(backend.discards, 1);
      expect(() => notifier.credential(), throwsA(isA<NotSignedIn>()));
    },
  );

  scenario('AuthEnded can give any reason', () async {
    backend.renewError = const AuthEnded(SignOutReason.keyLost);
    await expectLater(
      later(notifier.credential(forceRenew: true)),
      throwsA(isA<AuthRejected>()),
    );
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.keyLost),
    );
  });

  scenario(
    'a renewal that could not run keeps the session, and the next call tries again',
    () async {
      backend.renewError = Exception('offline');
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final a = later(notifier.credential());
      final b = later(notifier.credential());
      final failures = [
        expectLater(a, throwsA(isA<AuthUnavailable>())),
        expectLater(b, throwsA(isA<AuthUnavailable>())),
      ];
      gate.complete();
      await Future.wait(failures);
      expect(container.read(authSession), isA<SignedIn>());
      expect(held(), 'fake-0');
      expect(backend.renewals, 1);
      expect(backend.discards, 0);
      expect(store.value, isNull, reason: 'nothing was written or cleared');

      backend.renewError = null;
      final next = await later(notifier.credential());
      expect(idOf(next), 'fake-1');
      expect(backend.renewals, 2);
    },
  );

  scenario(
    'an AuthUnavailable the backend threw is passed on as it is',
    () async {
      final error = AuthUnavailable(Exception('x'));
      backend.renewError = error;
      time.elapse(const Duration(minutes: 6));
      await expectLater(later(notifier.credential()), throwsA(same(error)));
    },
  );

  scenario(
    'an unavailable server is an AuthUnavailable that names the cause and no host',
    () async {
      backend.renewError = Exception('connection refused');
      time.elapse(const Duration(minutes: 6));
      try {
        await later(notifier.credential());
        fail('expected a failure');
      } on AuthUnavailable catch (e) {
        expect(e.cause, isA<Exception>());
        expect(
          '$e',
          "AuthUnavailable: couldn't renew the session: Exception: connection refused",
        );
      }
    },
  );

  scenario(
    'signing out during a renewal: the waiters get NotSignedIn, and it stays signed out',
    () async {
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final waiting = later(notifier.credential());
      final failure = expectLater(waiting, throwsA(isA<NotSignedIn>()));
      final out = notifier.signOut();
      gate.complete();
      await failure;
      await out;
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      expect(store.value, isNull, reason: 'the late credential was not stored');
      expect(storeLog.where((e) => e == 'write'), isEmpty);
    },
  );

  scenario(
    'a renewal that finishes after a new sign-in is thrown away',
    () async {
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final waiting = later(notifier.credential());
      final failure = expectLater(waiting, throwsA(isA<NotSignedIn>()));
      await notifier.signOut();
      // signIn waits for the gate too: complete it, the renewal was first in line.
      final signIn = notifier.signIn(const TestSignIn());
      gate.complete();
      await failure;
      await signIn;
      expect(container.read(authSession), isA<SignedIn>());
      expect(backend.renewals, 1);
      expect(
        held(),
        'fake-2',
        reason: 'the sign-in\'s credential, not the renewal\'s',
      );
      expect(backend.signIns, 1);
    },
  );

  scenario(
    'a refusal that arrives after the user signed out changes nothing',
    () async {
      backend.renewError = const AuthRejected();
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final waiting = later(notifier.credential());
      final failure = expectLater(waiting, throwsA(isA<AuthRejected>()));
      await notifier.signOut();
      gate.complete();
      await failure;
      await pumpEventQueue();
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
        reason: 'not rewritten to expired',
      );
    },
  );

  scenario(
    'a signed-out app has no credential: NotSignedIn, as a StateError',
    () async {
      await notifier.signOut();
      expect(() => notifier.credential(), throwsA(isA<NotSignedIn>()));
      expect(() => notifier.credential(), throwsStateError);
      expect(
        () => notifier.credential(),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'text',
            'Bad state: fespalier_auth: not signed in',
          ),
        ),
      );
    },
  );

  scenario(
    'a session with no expiry is used until a server says 401',
    () async {
      final open = containerFor(signedInAs: ada, backend: FakeAuthBackend());
      final n = open.read(authSession.notifier);
      time.elapse(const Duration(days: 30));
      expect(n.credential(), isA<FakeCredential>());
      // A 401 still renews it.
      final inUse = n.credential() as SessionCredential;
      expect(idOf(await later(n.credential(rejected: inUse))), 'fake-1');
    },
  );

  scenario(
    'a renewal that fails before its first await still clears the single flight',
    () async {
      final broken = _ThrowsAtOnce();
      final c = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: broken,
              transport: noTransport,
              store: MemoryTokenStore(),
            ),
          ),
          authInitialState.overrideWithValue(
            SignedIn(fakeSession(ada, lifetime: lifetime)),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(authSession.notifier);
      time.elapse(const Duration(minutes: 6));
      await expectLater(later(n.credential()), throwsA(isA<AuthUnavailable>()));
      broken.fail = false;
      expect(idOf(await later(n.credential())), 'fake-1');
    },
  );

  scenario(
    'asked while the stored session is still being read, it waits for it',
    () async {
      final gate = Completer<void>();
      final backend = FakeAuthBackend(credentialLifetime: lifetime);
      final s = fakeSession(ada, lifetime: lifetime);
      final c = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: backend,
              transport: noTransport,
              store: GatedStore(gate, _stored(s)),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(authSession.notifier);
      expect(c.read(authSession), const SessionRestoring());
      final pending = later(n.credential());
      gate.complete();
      expect(idOf(await pending), 'fake-0');
      expect(backend.renewals, 0);
    },
  );

  scenario(
    'asked while the stored session is being read and nobody is signed in: NotSignedIn',
    () async {
      final gate = Completer<void>();
      final c = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: FakeAuthBackend(),
              transport: noTransport,
              store: GatedStore(gate),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(authSession.notifier);
      final pending = n.credential();
      final failure = expectLater(pending, throwsA(isA<NotSignedIn>()));
      gate.complete();
      await failure;
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
        final b = FakeAuthBackend(credentialLifetime: lifetime);
        final c = containerFor(
          signedInAs: ada,
          backend: b,
          store: _WriteFails(),
          credentialLifetime: lifetime,
        );
        final n = c.read(authSession.notifier);
        t.elapse(const Duration(minutes: 6));
        final credential = await (n.credential() as Future<SessionCredential>);
        expect(idOf(credential), 'fake-1');
        expect(c.read(authSession), isA<SignedIn>());
      });
      expect(errors, hasLength(1));
      expect(errors.single.context.toString(), 'while storing the session');
    },
  );

  group('endSession', () {
    scenario(
      'is SignedOut(reason) at once, then clears the store and discards, with no call to the server',
      () async {
        store.value = 'kept';
        final states = <SessionState>[];
        container.listen(authSession, (_, next) => states.add(next));
        final done = notifier.endSession(SignOutReason.revoked);
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.revoked),
        );
        expect(states, [const SignedOut(reason: SignOutReason.revoked)]);
        await done;
        expect(store.value, isNull);
        expect(storeLog, contains('delete'));
        expect(backend.discards, 1);
        expect(backend.signOuts, 0);
      },
    );

    scenario('does nothing when nobody is signed in', () async {
      await notifier.signOut();
      final discards = backend.discards;
      storeLog.clear();
      await notifier.endSession(SignOutReason.revoked);
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      expect(storeLog, isEmpty);
      expect(backend.discards, discards);
    });

    scenario('only: ends the session when it is that user\'s', () async {
      await notifier.endSession(SignOutReason.revoked, only: ada.id);
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.revoked),
      );
      expect(backend.discards, 1);
    });

    scenario(
      'only: leaves another user\'s session alone, store and keys included',
      () async {
        storeLog.clear();
        await notifier.endSession(SignOutReason.revoked, only: bob.id);
        expect(container.read(authSession), isA<SignedIn>());
        expect(storeLog, isEmpty);
        expect(backend.discards, 0);
      },
    );

    scenario('a renewal running when it ends is thrown away', () async {
      time.elapse(const Duration(minutes: 6));
      final gate = backend.gate = Completer<void>();
      final waiting = later(notifier.credential());
      final failure = expectLater(waiting, throwsA(isA<NotSignedIn>()));
      await notifier.endSession(SignOutReason.revoked);
      gate.complete();
      await failure;
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.revoked),
      );
      expect(storeLog.where((e) => e == 'write'), isEmpty);
      // And a later call does not join the dead renewal.
      expect(() => notifier.credential(), throwsA(isA<NotSignedIn>()));
    });

    scenario('can be followed by a new sign-in', () async {
      await notifier.endSession(SignOutReason.revoked);
      await notifier.signIn(const TestSignIn());
      expect(container.read(authSession), isA<SignedIn>());
    });

    scenario('a discard that throws is swallowed', () async {
      final failing = _DiscardFails();
      final c = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: failing,
              transport: noTransport,
              store: MemoryTokenStore('x'),
            ),
          ),
          authInitialState.overrideWithValue(SignedIn(fakeSession(ada))),
        ],
      );
      addTearDown(c.dispose);
      await c.read(authSession.notifier).endSession(SignOutReason.keyLost);
      expect(
        c.read(authSession),
        const SignedOut(reason: SignOutReason.keyLost),
      );
      expect(failing.discards, 1);
    });
  });
}

String _stored(AuthSession session) => jsonEncode(session.toJson());

/// A backend whose renewal throws before it awaits anything (a synchronous failure).
final class _ThrowsAtOnce extends StubBackend {
  _ThrowsAtOnce();

  bool fail = true;

  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) {
    if (fail) throw Exception('no network at all');
    return Future.value(
      session.copyWith(credential: const FakeCredential(id: 'fake-1')),
    );
  }
}

final class _DiscardFails extends StubBackend {
  _DiscardFails();

  int discards = 0;

  @override
  Future<void> discard(AuthSession session) async {
    discards++;
    throw StateError('keystore locked');
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
