// restoreAuth: the stored session becomes the first state, with no network, and synchronously
// when the store answers synchronously.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

String stored(AuthSession session) => jsonEncode(session.toJson());

AuthSession session({
  String backend = 'fake',
  DateTime? expiresAt,
  DateTime? renewableUntil,
  bool renewable = true,
}) => AuthSession(
  backend: backend,
  credential: FakeCredential(
    id: 'fake-0',
    expiresAt: expiresAt,
    renewableUntil: renewableUntil,
    renewable: renewable,
  ),
  user: ada,
);

AuthConfig configOf(
  AuthBackend backend,
  TokenStore store, {
  List<Uri> apiOrigins = const [],
}) => AuthConfig(
  backend: backend,
  transport: noTransport,
  store: store,
  apiOrigins: apiOrigins,
);

SessionState stateOf(List<Override> overrides) {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  return container.read(authSession);
}

/// What the Flutter error handler is told while the test runs.
List<FlutterErrorDetails> captureErrors() {
  final errors = <FlutterErrorDetails>[];
  final old = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = old);
  return errors;
}

void main() {
  late RecordingTelemetry rec;
  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('with a synchronous store', () {
    test('restoreAuth returns the overrides at once, not a Future', () {
      final result = restoreAuth(
        configOf(FakeAuthBackend(), MemoryTokenStore()),
      );
      expect(result, isA<List<Override>>());
      expect(result, isNot(isA<Future<Object?>>()));
    });

    test('nothing stored: signed out, and the span says none', () {
      final result = restoreAuth(
        configOf(FakeAuthBackend(), MemoryTokenStore()),
      );
      expect(stateOf(result as List<Override>), const SignedOut());
      expect(rec.log, [
        '#1 start auth restore backend=fake scheme=fake',
        '#1 end auth none',
      ]);
    });

    test(
      'a stored session: signed in from the first read, the credential read by the backend',
      () {
        final store = MemoryTokenStore(stored(session()));
        final result = restoreAuth(configOf(FakeAuthBackend(), store));
        final state = stateOf(result as List<Override>);
        expect(state, isA<SignedIn>());
        expect(state.user, ada);
        expect(
          (state as SignedIn).session.credential,
          isA<FakeCredential>().having((c) => c.id, 'id', 'fake-0'),
        );
        expect(rec.log, [
          '#1 start auth restore backend=fake scheme=fake',
          '#1 end auth ok',
        ]);
        expect(store.value, isNotNull, reason: 'a kept session stays stored');
      },
    );

    test('the config is overridden too, so the rest of the app reads it', () {
      final config = configOf(FakeAuthBackend(), MemoryTokenStore());
      final container = ProviderContainer(
        overrides: restoreAuth(config) as List<Override>,
      );
      addTearDown(container.dispose);
      expect(container.read(authConfig), same(config));
    });

    test('corrupt JSON is reported once, dropped, and signed out', () {
      final errors = captureErrors();
      final log = <String>[];
      final store = SpyStore(log, '{not json');
      final result = restoreAuth(configOf(FakeAuthBackend(), store));
      expect(stateOf(result as List<Override>), const SignedOut());
      expect(store.value, isNull);
      expect(errors, hasLength(1));
      expect(errors.single.exception, isA<FormatException>());
      expect(errors.single.library, 'fespalier_auth');
      expect(
        errors.single.context.toString(),
        'while restoring the stored session',
      );
      expect(
        errors.single.toString().replaceAll(RegExp(r'\s+'), ' '),
        contains(
          'The following FormatException was thrown while restoring the stored session:',
        ),
      );
      expect(rec.log.last, '#1 end auth error');
    });

    test('JSON that is not a session is just as corrupt', () {
      final errors = captureErrors();
      final good = session().toJson();
      for (final raw in [
        '[]',
        '{"v":2}',
        '{"v":3,"backend":"fake"}',
        jsonEncode({...good, 'credential': 'x'}),
        jsonEncode({
          ...good,
          'credential': {'id': 1},
        }),
        jsonEncode({...good, 'user': null}),
      ]) {
        final store = MemoryTokenStore(raw);
        final result = restoreAuth(configOf(FakeAuthBackend(), store));
        expect(
          stateOf(result as List<Override>),
          const SignedOut(),
          reason: raw,
        );
        expect(store.value, isNull, reason: raw);
      }
      expect(errors, hasLength(6));
    });

    test(
      'a session of version 1 (0.20.0 and before) is dropped and reported: the user signs in once more',
      () {
        final errors = captureErrors();
        final store = MemoryTokenStore(
          jsonEncode({
            'v': 1,
            'backend': 'fake',
            'tokens': {'accessToken': 'old', 'tokenType': 'Bearer'},
            'user': ada.toJson(),
          }),
        );
        final result = restoreAuth(configOf(FakeAuthBackend(), store));
        expect(stateOf(result as List<Override>), const SignedOut());
        expect(store.value, isNull);
        expect(errors, hasLength(1));
        expect(errors.single.exception, isA<FormatException>());
        expect(rec.log.last, '#1 end auth error');
      },
    );

    test('a stored text that is not an object is reported and dropped', () {
      final errors = captureErrors();
      final store = MemoryTokenStore('"just a string"');
      final result = restoreAuth(configOf(FakeAuthBackend(), store));
      expect(stateOf(result as List<Override>), const SignedOut());
      expect(store.value, isNull);
      expect(errors.single.exception, isA<FormatException>());
    });

    test("another backend's session is dropped silently, and deleted", () {
      final errors = captureErrors();
      final store = MemoryTokenStore(stored(session(backend: 'firebase')));
      final result = restoreAuth(configOf(FakeAuthBackend(), store));
      expect(stateOf(result as List<Override>), const SignedOut());
      expect(store.value, isNull);
      expect(errors, isEmpty, reason: 'it is not corrupt: nothing to report');
      expect(rec.log.last, '#1 end auth none');
    });

    test(
      "another backend's session is not handed to this backend's credential reader",
      () {
        final backend = _CountingReader();
        final store = MemoryTokenStore(stored(session(backend: 'firebase')));
        final result = restoreAuth(configOf(backend, store));
        stateOf(result as List<Override>);
        expect(backend.reads, 0);
      },
    );

    test('a renewableUntil that has passed signs out with reason expired', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            renewableUntil: time.now.subtract(const Duration(seconds: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(configOf(FakeAuthBackend(), store)),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(store.value, isNull);
      expect(rec.log.last, '#1 end auth expired');
    });

    test('a renewableUntil that is exactly now has passed too', () {
      final time = TestTime();
      final store = MemoryTokenStore(stored(session(renewableUntil: time.now)));
      final result = time.run(
        () => restoreAuth(configOf(FakeAuthBackend(), store)),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.expired),
      );
    });

    test(
      'a renewable credential past its expiresAt is kept, offline too: it is renewed lazily',
      () {
        final time = TestTime();
        final store = MemoryTokenStore(
          stored(
            session(
              renewableUntil: time.now.add(const Duration(minutes: 1)),
              expiresAt: time.now.subtract(const Duration(minutes: 1)),
            ),
          ),
        );
        final backend = FakeAuthBackend();
        final result = time.run(() => restoreAuth(configOf(backend, store)));
        expect(stateOf(result as List<Override>), isA<SignedIn>());
        expect(backend.renewals, 0, reason: 'restore never renews');
        expect(store.value, isNotNull);
      },
    );

    test('a renewable credential with no renewableUntil is kept too', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(session(expiresAt: time.now.subtract(const Duration(days: 30)))),
      );
      final backend = FakeAuthBackend();
      final result = time.run(() => restoreAuth(configOf(backend, store)));
      expect(stateOf(result as List<Override>), isA<SignedIn>());
      expect(backend.renewals, 0);
    });

    test('an expired credential that cannot be renewed is expired', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            renewable: false,
            expiresAt: time.now.subtract(const Duration(seconds: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(configOf(FakeAuthBackend(), store)),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(store.value, isNull);
      expect(rec.log.last, '#1 end auth expired');
    });

    test('a credential that cannot be renewed but has not expired is kept', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            renewable: false,
            expiresAt: time.now.add(const Duration(minutes: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(configOf(FakeAuthBackend(), store)),
      );
      expect(stateOf(result as List<Override>), isA<SignedIn>());
    });

    test('a credential that cannot be renewed and never expires is kept', () {
      final store = MemoryTokenStore(stored(session(renewable: false)));
      final result = restoreAuth(configOf(FakeAuthBackend(), store));
      expect(stateOf(result as List<Override>), isA<SignedIn>());
    });

    test(
      'the backend refusing the session (check): dropped with that reason, and the store is cleared',
      () {
        for (final reason in [SignOutReason.keyLost, SignOutReason.revoked]) {
          final backend = FakeAuthBackend()..checkResult = reason;
          final store = MemoryTokenStore(stored(session()));
          final result = restoreAuth(configOf(backend, store));
          expect(
            stateOf(result as List<Override>),
            SignedOut(reason: reason),
            reason: '$reason',
          );
          expect(store.value, isNull, reason: '$reason');
        }
      },
    );

    test(
      'check runs after the expiry rule: an expired session is not asked',
      () {
        final time = TestTime();
        final backend = _CheckSpy();
        final store = MemoryTokenStore(
          stored(
            session(
              renewableUntil: time.now.subtract(const Duration(seconds: 1)),
            ),
          ),
        );
        final result = time.run(() => restoreAuth(configOf(backend, store)));
        expect(
          stateOf(result as List<Override>),
          const SignedOut(reason: SignOutReason.expired),
        );
        expect(backend.checked, 0);
      },
    );

    test('check is asked about a session that is kept', () {
      final backend = _CheckSpy();
      final store = MemoryTokenStore(stored(session()));
      final result = restoreAuth(configOf(backend, store));
      expect(stateOf(result as List<Override>), isA<SignedIn>());
      expect(backend.checked, 1);
    });

    test('a store that fails to read makes restoreAuth throw', () {
      expect(
        () => restoreAuth(configOf(FakeAuthBackend(), _Broken())),
        throwsStateError,
      );
      expect(rec.log, [
        '#1 start auth restore backend=fake scheme=fake',
        '#1 end auth error error=Bad state: keychain locked',
      ]);
    });

    test('a store that fails to delete does not fail a restore', () {
      final errors = captureErrors();
      final store = _DeleteFails('{not json');
      final result = restoreAuth(configOf(FakeAuthBackend(), store));
      expect(stateOf(result as List<Override>), const SignedOut());
      expect(errors, hasLength(1), reason: 'only the corrupt text is reported');
    });
  });

  group('with a store that answers later', () {
    test('restoreAuth returns a Future of the overrides', () async {
      FlutterSecureStorage.setMockInitialValues({
        'fespalier_auth.session': stored(session()),
      });
      final result = restoreAuth(
        configOf(FakeAuthBackend(), const SecureTokenStore()),
      );
      expect(result, isA<Future<List<Override>>>());
      expect(stateOf(await result), isA<SignedIn>());
      expect(rec.log, [
        '#1 start auth restore backend=fake scheme=fake',
        '#1 end auth ok async',
      ]);
    });

    test('nothing stored in the keychain: signed out', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final result = restoreAuth(
        configOf(FakeAuthBackend(), const SecureTokenStore()),
      );
      expect(stateOf(await result), const SignedOut());
      expect(rec.log.last, '#1 end auth none async');
    });

    test(
      'a corrupt stored session in the keychain is reported and dropped',
      () async {
        final errors = captureErrors();
        final data = <String, String>{'fespalier_auth.session': 'garbage'};
        FlutterSecureStorage.setMockInitialValues(data);
        final result = restoreAuth(
          configOf(FakeAuthBackend(), const SecureTokenStore()),
        );
        expect(stateOf(await result), const SignedOut());
        expect(data, isEmpty);
        expect(errors, hasLength(1));
        expect(rec.log.last, '#1 end auth error async');
      },
    );

    test('an asynchronous check makes restore async, and decides', () async {
      final backend = _AsyncCheck(SignOutReason.keyLost);
      final store = MemoryTokenStore(stored(session()));
      final good = restoreAuth(
        configOf(_AsyncCheck(null), MemoryTokenStore(stored(session()))),
      );
      expect(good, isA<Future<List<Override>>>());
      expect(stateOf(await good), isA<SignedIn>());
      expect(rec.log.last, '#1 end auth ok async');

      final lost = restoreAuth(configOf(backend, store));
      expect(lost, isA<Future<List<Override>>>());
      expect(
        stateOf(await lost),
        const SignedOut(reason: SignOutReason.keyLost),
      );
      expect(store.value, isNull);
      expect(rec.log.last, '#2 end auth expired async');
    });
  });

  group('a backend that keeps its own session', () {
    test('is asked for it, and the store is never used', () {
      final log = <String>[];
      final backend = _OwnSession(
        AuthSession(
          backend: 'own',
          credential: const FakeCredential(id: 'sdk'),
          user: ada,
        ),
      );
      final store = SpyStore(log);
      final result = restoreAuth(configOf(backend, store));
      expect(
        result,
        isA<List<Override>>(),
        reason: 'a sync currentSession keeps restore sync',
      );
      expect(stateOf(result as List<Override>), isA<SignedIn>());
      expect(log, isEmpty);
      expect(rec.log.last, '#1 end auth ok');
    });

    test('signed out when the SDK has no user', () {
      final result = restoreAuth(
        configOf(const _OwnSession(null), MemoryTokenStore()),
      );
      expect(stateOf(result as List<Override>), const SignedOut());
    });

    test('an SDK that answers later makes restore async', () async {
      final backend = const _OwnSession(null, later: true);
      final result = restoreAuth(configOf(backend, MemoryTokenStore()));
      expect(result, isA<Future<List<Override>>>());
      expect(stateOf(await result), const SignedOut());
    });

    test(
      'its session is not held to the stored-session rules: no expiry check, store untouched',
      () {
        final time = TestTime();
        final log = <String>[];
        final backend = _OwnSession(
          AuthSession(
            backend: 'own',
            credential: FakeCredential(
              id: 'sdk',
              expiresAt: time.now.subtract(const Duration(hours: 1)),
              renewable: false,
            ),
            user: ada,
          ),
        );
        final store = SpyStore(log, 'kept');
        final result = time.run(() => restoreAuth(configOf(backend, store)));
        expect(stateOf(result as List<Override>), isA<SignedIn>());
        expect(log, isEmpty);
        expect(store.value, 'kept');
      },
    );

    test('check still decides', () {
      final backend = _OwnSession(
        AuthSession(
          backend: 'own',
          credential: const FakeCredential(id: 'sdk'),
          user: ada,
        ),
        checkResult: SignOutReason.revoked,
      );
      final log = <String>[];
      final result = restoreAuth(configOf(backend, SpyStore(log)));
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.revoked),
      );
      expect(log, isEmpty, reason: 'there is no store to clear');
    });
  });

  group('without restoreAuth in startup()', () {
    test(
      'a synchronous store: the notifier restores by itself, at the first read',
      () {
        final store = MemoryTokenStore(stored(session()));
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(configOf(FakeAuthBackend(), store)),
          ],
        );
        addTearDown(container.dispose);
        expect(container.read(authSession), isA<SignedIn>());
      },
    );

    test(
      'a store that answers later: SessionRestoring, then the state, and ready completes',
      () async {
        final gate = Completer<void>();
        final store = GatedStore(gate, stored(session()));
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(configOf(FakeAuthBackend(), store)),
          ],
        );
        addTearDown(container.dispose);
        final seen = <SessionState>[];
        container.listen(
          authSession,
          (_, next) => seen.add(next),
          fireImmediately: true,
        );
        expect(container.read(authSession), const SessionRestoring());
        final ready = container.read(authSession.notifier).ready;
        var done = false;
        unawaited(ready.then((_) => done = true));
        await pumpEventQueue();
        expect(done, isFalse);

        gate.complete();
        final state = await ready;
        expect(state, isA<SignedIn>());
        expect(container.read(authSession), isA<SignedIn>());
        expect(seen.map((s) => s.runtimeType), [SessionRestoring, SignedIn]);
      },
    );

    test(
      'a store that fails to read is reported and answers signed out',
      () async {
        final errors = captureErrors();
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              configOf(FakeAuthBackend(), _Broken()),
            ),
          ],
        );
        addTearDown(container.dispose);
        expect(container.read(authSession), const SignedOut());
        expect(errors.single.exception, isA<StateError>());
        expect(errors.single.library, 'fespalier_auth');
      },
    );

    test(
      'a gated store that fails to read is reported, and the wait ends signed out',
      () async {
        final errors = captureErrors();
        final gate = Completer<void>();
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              configOf(FakeAuthBackend(), _GatedBroken(gate)),
            ),
          ],
        );
        addTearDown(container.dispose);
        final notifier = container.read(authSession.notifier);
        expect(container.read(authSession), const SessionRestoring());
        gate.complete();
        expect(await notifier.ready, const SignedOut());
        expect(container.read(authSession), const SignedOut());
        expect(errors, hasLength(1));
      },
    );

    test('a sign-in while it restores wins, and ends the wait', () async {
      final gate = Completer<void>();
      final backend = FakeAuthBackend();
      final container = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            configOf(backend, GatedStore(gate, stored(session()))),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(authSession.notifier);
      expect(container.read(authSession), const SessionRestoring());
      await notifier.signIn(const TestSignIn());
      expect(container.read(authSession), isA<SignedIn>());
      expect(await notifier.ready, isA<SignedIn>());
      gate.complete();
      await pumpEventQueue();
      expect(
        (container.read(authSession) as SignedIn).session.credential,
        isA<FakeCredential>().having((c) => c.id, 'id', 'fake-1'),
        reason: 'the late restore did not overwrite the sign-in',
      );
    });

    test('a container disposed while restoring does not hang ready', () async {
      final gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            configOf(FakeAuthBackend(), GatedStore(gate, stored(session()))),
          ),
        ],
      );
      final ready = container.read(authSession.notifier).ready;
      container.dispose();
      expect(await ready, const SignedOut());
    });
  });

  group('the configuration', () {
    test('reading authConfig with no override says what to do', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      Object? thrown;
      try {
        container.read(authConfig);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(
        '$thrown',
        contains(
          'fespalier_auth: no AuthConfig. Return restoreAuth(config) from startup() in '
          'lib/app/startup.dart, or add authConfig.overrideWithValue(config) to your '
          'ProviderScope; in a test, pass overrides: fakeAuth(...) to pumpRouter.',
        ),
      );
    });

    test(
      'an AuthConfig takes a transport, and has no apiOrigins by default',
      () {
        final transport = FakeTransport((_, _) => fakeResponse(200));
        final config = AuthConfig(
          backend: FakeAuthBackend(),
          transport: transport,
        );
        expect(config.transport, same(transport));
        expect(config.apiOrigins, isEmpty);
        expect(config.store, isA<SecureTokenStore>());
      },
    );
  });
}

final class _Broken implements TokenStore {
  @override
  String? read() => throw StateError('keychain locked');

  @override
  void write(String value) {}

  @override
  void delete() {}
}

final class _GatedBroken implements TokenStore {
  _GatedBroken(this.gate);

  final Completer<void> gate;

  @override
  Future<String?> read() async {
    await gate.future;
    throw StateError('keychain locked');
  }

  @override
  void write(String value) {}

  @override
  void delete() {}
}

final class _DeleteFails implements TokenStore {
  _DeleteFails(this.value);

  final String value;

  @override
  String? read() => value;

  @override
  void write(String value) {}

  @override
  void delete() => throw StateError('cannot delete');
}

final class _CountingReader extends StubBackend {
  _CountingReader();

  int reads = 0;

  @override
  SessionCredential readCredential(Map<String, Object?> json) {
    reads++;
    return super.readCredential(json);
  }
}

final class _CheckSpy extends StubBackend {
  _CheckSpy();

  int checked = 0;

  @override
  FutureOr<SignOutReason?> check(AuthSession session) {
    checked++;
    return null;
  }
}

final class _AsyncCheck extends StubBackend {
  const _AsyncCheck(this.result);

  final SignOutReason? result;

  @override
  FutureOr<SignOutReason?> check(AuthSession session) async => result;
}

final class _OwnSession extends StubBackend {
  const _OwnSession(this.session, {this.later = false, this.checkResult})
    : super('own');

  final AuthSession? session;
  final bool later;
  final SignOutReason? checkResult;

  @override
  bool get keepsOwnSession => true;

  @override
  FutureOr<AuthSession?> currentSession() =>
      later ? Future.value(session) : session;

  @override
  FutureOr<SignOutReason?> check(AuthSession session) => checkResult;
}
