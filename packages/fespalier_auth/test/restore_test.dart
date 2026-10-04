// restoreAuth: the stored session becomes the first state, with no network, and synchronously
// when the store answers synchronously.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

String stored(AuthSession session) => jsonEncode(session.toJson());

AuthSession session({
  String backend = 'fake',
  String? binding,
  DateTime? refreshExpiresAt,
  bool refreshToken = true,
  DateTime? expiresAt,
}) => AuthSession(
  backend: backend,
  tokens: AuthTokens(
    accessToken: 'fake-access-0',
    tokenType: binding == null ? 'Bearer' : 'DPoP',
    refreshToken: refreshToken ? 'fake-refresh-0' : null,
    expiresAt: expiresAt,
    refreshExpiresAt: refreshExpiresAt,
  ),
  user: ada,
  binding: binding,
);

SessionState stateOf(List<Override> overrides) {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  return container.read(authSession);
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
        AuthConfig(backend: FakeAuthBackend(), store: MemoryTokenStore()),
      );
      expect(result, isA<List<Override>>());
      expect(result, isNot(isA<Future<Object?>>()));
    });

    test('nothing stored: signed out, and the span says none', () {
      final result = restoreAuth(
        AuthConfig(backend: FakeAuthBackend(), store: MemoryTokenStore()),
      );
      expect(stateOf(result as List<Override>), const SignedOut());
      expect(rec.log, [
        '#1 start auth restore backend=fake',
        '#1 end auth none',
      ]);
    });

    test('a stored session: signed in from the first read', () {
      final store = MemoryTokenStore(stored(session()));
      final result = restoreAuth(
        AuthConfig(backend: FakeAuthBackend(), store: store),
      );
      final state = stateOf(result as List<Override>);
      expect(state, isA<SignedIn>());
      expect(state.user, ada);
      expect(rec.log, ['#1 start auth restore backend=fake', '#1 end auth ok']);
    });

    test('the config is overridden too, so the rest of the app reads it', () {
      final config = AuthConfig(
        backend: FakeAuthBackend(),
        store: MemoryTokenStore(),
      );
      final container = ProviderContainer(
        overrides: restoreAuth(config) as List<Override>,
      );
      addTearDown(container.dispose);
      expect(container.read(authConfig), same(config));
    });

    test('corrupt JSON is reported once, dropped, and signed out', () {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
      final log = <String>[];
      final store = SpyStore(log, '{not json');
      final result = restoreAuth(
        AuthConfig(backend: FakeAuthBackend(), store: store),
      );
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
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = old);
      for (final raw in ['[]', '{"v":2}', '{"v":1,"backend":"fake"}']) {
        final store = MemoryTokenStore(raw);
        final result = restoreAuth(
          AuthConfig(backend: FakeAuthBackend(), store: store),
        );
        expect(
          stateOf(result as List<Override>),
          const SignedOut(),
          reason: raw,
        );
        expect(store.value, isNull, reason: raw);
      }
      expect(errors, hasLength(3));
    });

    test("another backend's session is dropped, and deleted", () {
      final store = MemoryTokenStore(stored(session(backend: 'firebase')));
      final result = restoreAuth(
        AuthConfig(backend: FakeAuthBackend(), store: store),
      );
      expect(stateOf(result as List<Override>), const SignedOut());
      expect(store.value, isNull);
      expect(rec.log.last, '#1 end auth none');
    });

    test('a refresh token that has expired signs out with reason expired', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            refreshExpiresAt: time.now.subtract(const Duration(seconds: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(AuthConfig(backend: FakeAuthBackend(), store: store)),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.expired),
      );
      expect(store.value, isNull);
      expect(rec.log.last, '#1 end auth expired');
    });

    test('a refresh token that is still good keeps the session, offline too', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            refreshExpiresAt: time.now.add(const Duration(minutes: 1)),
            // The access token has expired: it is refreshed by the first request, not at start-up.
            expiresAt: time.now.subtract(const Duration(minutes: 1)),
          ),
        ),
      );
      final backend = FakeAuthBackend();
      final result = time.run(
        () => restoreAuth(AuthConfig(backend: backend, store: store)),
      );
      expect(stateOf(result as List<Override>), isA<SignedIn>());
      expect(backend.refreshes, 0, reason: 'restore never refreshes');
    });

    test('an expired access token with nothing to renew it is expired', () {
      final time = TestTime();
      final store = MemoryTokenStore(
        stored(
          session(
            refreshToken: false,
            expiresAt: time.now.subtract(const Duration(seconds: 1)),
          ),
        ),
      );
      final result = time.run(
        () => restoreAuth(AuthConfig(backend: FakeAuthBackend(), store: store)),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.expired),
      );
    });

    test('a session bound to a key, and no proof: the key is lost', () {
      final store = MemoryTokenStore(stored(session(binding: 'thumb')));
      final result = restoreAuth(
        AuthConfig(backend: FakeAuthBackend(), store: store),
      );
      expect(
        stateOf(result as List<Override>),
        const SignedOut(reason: SignOutReason.keyLost),
      );
      expect(store.value, isNull);
    });

    test('a store that fails to read makes restoreAuth throw', () {
      expect(
        () => restoreAuth(
          AuthConfig(backend: FakeAuthBackend(), store: _Broken()),
        ),
        throwsStateError,
      );
      expect(rec.log, [
        '#1 start auth restore backend=fake',
        '#1 end auth error error=Bad state: keychain locked',
      ]);
    });
  });

  group('with a store that answers later', () {
    test('restoreAuth returns a Future of the overrides', () async {
      FlutterSecureStorage.setMockInitialValues({
        'fespalier_auth.session': stored(session()),
      });
      final result = restoreAuth(
        AuthConfig(backend: FakeAuthBackend(), store: const SecureTokenStore()),
      );
      expect(result, isA<Future<List<Override>>>());
      expect(stateOf(await result), isA<SignedIn>());
      expect(rec.log, [
        '#1 start auth restore backend=fake',
        '#1 end auth ok async',
      ]);
    });

    test('nothing stored in the keychain: signed out', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final result = restoreAuth(
        AuthConfig(backend: FakeAuthBackend(), store: const SecureTokenStore()),
      );
      expect(stateOf(await result), const SignedOut());
    });

    test(
      'a key that matches keeps the session, one that does not loses it',
      () async {
        final proof = FakeProof(thumbprintValue: 'this-device');
        final backend = FakeAuthBackend(proof: proof);
        final good = restoreAuth(
          AuthConfig(
            backend: backend,
            store: MemoryTokenStore(stored(session(binding: 'this-device'))),
          ),
        );
        expect(
          good,
          isA<Future<List<Override>>>(),
          reason: 'the thumbprint is async',
        );
        expect(stateOf(await good), isA<SignedIn>());
        expect(rec.log.first, '#1 start auth restore backend=fake dpop');

        final store = MemoryTokenStore(
          stored(session(binding: 'another-device')),
        );
        final lost = restoreAuth(AuthConfig(backend: backend, store: store));
        expect(
          stateOf(await lost),
          const SignedOut(reason: SignOutReason.keyLost),
        );
        expect(store.value, isNull);
        expect(rec.log.last, '#2 end auth expired async');
      },
    );
  });

  group('a backend that keeps its own session', () {
    test('is asked for it, and the store is never used', () async {
      final log = <String>[];
      final backend = _OwnSession(
        AuthSession(
          backend: 'own',
          tokens: const AuthTokens(accessToken: 'sdk-token'),
          user: ada,
        ),
      );
      final store = SpyStore(log);
      final result = restoreAuth(AuthConfig(backend: backend, store: store));
      expect(
        result,
        isA<List<Override>>(),
        reason: 'a sync currentSession keeps restore sync',
      );
      expect(stateOf(result as List<Override>), isA<SignedIn>());
      expect(log, isEmpty);
    });

    test('signed out when the SDK has no user', () {
      final result = restoreAuth(
        AuthConfig(backend: _OwnSession(null), store: MemoryTokenStore()),
      );
      expect(stateOf(result as List<Override>), const SignedOut());
    });

    test('an SDK that answers later makes restore async', () async {
      final backend = _OwnSession(null, later: true);
      final result = restoreAuth(
        AuthConfig(backend: backend, store: MemoryTokenStore()),
      );
      expect(result, isA<Future<List<Override>>>());
      expect(stateOf(await result), const SignedOut());
    });
  });

  group('without restoreAuth in startup()', () {
    test(
      'a synchronous store: the notifier restores by itself, at the first read',
      () {
        final store = MemoryTokenStore(stored(session()));
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(backend: FakeAuthBackend(), store: store),
            ),
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
            authConfig.overrideWithValue(
              AuthConfig(backend: FakeAuthBackend(), store: store),
            ),
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
        final errors = <FlutterErrorDetails>[];
        final old = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = old);
        final container = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(backend: FakeAuthBackend(), store: _Broken()),
            ),
          ],
        );
        addTearDown(container.dispose);
        expect(container.read(authSession), const SignedOut());
        expect(errors.single.exception, isA<StateError>());
        expect(errors.single.library, 'fespalier_auth');
      },
    );

    test('a sign-in while it restores wins, and ends the wait', () async {
      final gate = Completer<void>();
      final backend = FakeAuthBackend();
      final container = ProviderContainer(
        overrides: [
          authConfig.overrideWithValue(
            AuthConfig(
              backend: backend,
              store: GatedStore(gate, stored(session())),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(authSession.notifier);
      expect(container.read(authSession), const SessionRestoring());
      await notifier.signIn(
        const PasswordSignIn(username: 'bob', password: 'bob'),
      );
      expect(container.read(authSession), isA<SignedIn>());
      expect(await notifier.ready, isA<SignedIn>());
      gate.complete();
      await pumpEventQueue();
      expect(
        (container.read(authSession) as SignedIn).session.tokens.accessToken,
        'fake-access-1',
      );
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

final class _OwnSession extends AuthBackend {
  const _OwnSession(this.session, {this.later = false});

  final AuthSession? session;
  final bool later;

  @override
  String get name => 'own';

  @override
  bool get keepsOwnSession => true;

  @override
  FutureOr<AuthSession?> currentSession() =>
      later ? Future.value(session) : session;

  @override
  Future<AuthSession> signIn(SignInRequest request) =>
      throw UnimplementedError();

  @override
  Future<AuthSession> refresh(AuthSession session) =>
      throw UnimplementedError();

  @override
  Future<void> signOut(AuthSession session) async {}
}
