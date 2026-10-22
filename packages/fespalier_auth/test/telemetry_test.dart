// What fespalier_auth tells the installed sink: one span per restore, sign-in, renewal and
// sign-out, with the backend's and the scheme's constant names and nothing that identifies
// anybody.
import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const lifetime = Duration(minutes: 5);

void main() {
  late RecordingTelemetry rec;
  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() => FespalierTelemetry.install(null));

  ProviderContainer signedOutOn(FakeAuthBackend backend) {
    final result = restoreAuth(
      AuthConfig(
        backend: backend,
        transport: noTransport,
        store: MemoryTokenStore(),
      ),
    );
    final container = ProviderContainer(overrides: result as List<Override>);
    addTearDown(container.dispose);
    return container;
  }

  test('restore: a span at start-up, none when nothing was stored', () {
    signedOutOn(FakeAuthBackend());
    expect(rec.log, [
      '#1 start auth restore backend=fake scheme=fake',
      '#1 end auth none',
    ]);
  });

  test('sign-in, then sign-out: ok and async', () async {
    final container = signedOutOn(FakeAuthBackend(user: ada));
    rec.log.clear();
    final notifier = container.read(authSession.notifier);
    await notifier.signIn(const TestSignIn());
    await notifier.signOut();
    expect(rec.log, [
      '#2 start auth sign_in backend=fake scheme=fake',
      '#2 end auth ok async',
      '#3 start auth sign_out backend=fake scheme=fake',
      '#3 end auth ok async',
    ]);
  });

  test('adopting a session is a sign_in span too', () async {
    final container = signedOutOn(FakeAuthBackend(user: ada));
    rec.log.clear();
    await container.read(authSession.notifier).adopt(fakeSession(bob));
    expect(rec.log, [
      '#2 start auth sign_in backend=fake scheme=fake',
      '#2 end auth ok async',
    ]);
  });

  test('a renewal says what asked for it', () async {
    final time = TestTime();
    await time.run(() async {
      final backend = FakeAuthBackend(credentialLifetime: lifetime);
      final container = containerFor(
        signedInAs: ada,
        backend: backend,
        credentialLifetime: lifetime,
      );
      final notifier = container.read(authSession.notifier);
      time.elapse(const Duration(minutes: 6));
      await (notifier.credential() as Future<SessionCredential>);
      final inUse = notifier.credential() as SessionCredential;
      await (notifier.credential(rejected: inUse) as Future<SessionCredential>);
      await (notifier.credential(forceRenew: true)
          as Future<SessionCredential>);
      expect(rec.log, [
        '#1 start auth renew backend=fake trigger=expired scheme=fake',
        '#1 end auth ok async',
        '#2 start auth renew backend=fake trigger=unauthorized scheme=fake',
        '#2 end auth ok async',
        '#3 start auth renew backend=fake trigger=forced scheme=fake',
        '#3 end auth ok async',
      ]);
    });
  });

  test('a renewal is a renew span, never a refresh one', () async {
    final container = containerFor(signedInAs: ada);
    await (container.read(authSession.notifier).credential(forceRenew: true)
        as Future<SessionCredential>);
    expect(rec.log.join('\n'), isNot(contains('refresh')));
    expect(rec.log.first, contains(' renew '));
  });

  test('the scheme is the backend\'s scheme, not its name', () {
    final backend = _SchemeBackend();
    restoreAuth(
      AuthConfig(
        backend: backend,
        transport: noTransport,
        store: MemoryTokenStore(),
      ),
    );
    expect(rec.log.first, '#1 start auth restore backend=device scheme=signed');
  });

  test('a shared renewal is one span, however many wait', () async {
    final time = TestTime();
    await time.run(() async {
      final backend = FakeAuthBackend(credentialLifetime: lifetime);
      final container = containerFor(
        signedInAs: ada,
        backend: backend,
        credentialLifetime: lifetime,
      );
      final notifier = container.read(authSession.notifier);
      time.elapse(const Duration(minutes: 6));
      await Future.wait([
        notifier.credential() as Future<SessionCredential>,
        notifier.credential() as Future<SessionCredential>,
        notifier.credential() as Future<SessionCredential>,
      ]);
      expect(
        rec.log.where((l) => l.contains('start auth renew')),
        hasLength(1),
      );
    });
  });

  test('a good credential asks for nothing: no span', () {
    final container = containerFor(signedInAs: ada);
    container.read(authSession.notifier).credential();
    expect(rec.log, isEmpty);
  });

  test('rejected, cancelled and error are told apart', () async {
    final backend = FakeAuthBackend();
    final container = signedOutOn(backend);
    final notifier = container.read(authSession.notifier);
    rec.log.clear();
    const request = TestSignIn();

    backend.signInError = const FieldErrors({'password': 'Wrong'});
    await expectLater(notifier.signIn(request), throwsA(isA<FieldErrors>()));
    backend.signInError = const AuthRejected();
    await expectLater(notifier.signIn(request), throwsA(isA<AuthRejected>()));
    backend.signInError = const AuthCancelled();
    await expectLater(notifier.signIn(request), throwsA(isA<AuthCancelled>()));
    backend.signInError = StateError('the network is down');
    await expectLater(notifier.signIn(request), throwsStateError);

    expect(rec.log, [
      '#2 start auth sign_in backend=fake scheme=fake',
      '#2 end auth rejected async',
      '#3 start auth sign_in backend=fake scheme=fake',
      '#3 end auth rejected async',
      '#4 start auth sign_in backend=fake scheme=fake',
      '#4 end auth cancelled async',
      '#5 start auth sign_in backend=fake scheme=fake',
      '#5 end auth error async error=Bad state: the network is down',
    ]);
  });

  test(
    'a renewal that is refused is rejected; one that cannot run is an error',
    () async {
      final time = TestTime();
      await time.run(() async {
        final backend = FakeAuthBackend(credentialLifetime: lifetime);
        final container = containerFor(
          signedInAs: ada,
          backend: backend,
          credentialLifetime: lifetime,
        );
        final notifier = container.read(authSession.notifier);
        time.elapse(const Duration(minutes: 6));
        backend.renewError = Exception('offline');
        await expectLater(
          notifier.credential() as Future<SessionCredential>,
          throwsA(isA<AuthUnavailable>()),
        );
        backend.renewError = const AuthRejected();
        await expectLater(
          notifier.credential() as Future<SessionCredential>,
          throwsA(isA<AuthRejected>()),
        );
        expect(rec.log.where((l) => l.contains(' end ')), [
          "#1 end auth error async error=AuthUnavailable: couldn't renew the session: Exception: offline",
          '#2 end auth rejected async',
        ]);
      });
    },
  );

  test(
    'a renewal ended by the server with another reason is rejected too',
    () async {
      final backend = FakeAuthBackend();
      final container = containerFor(signedInAs: ada, backend: backend);
      backend.renewError = const AuthEnded(SignOutReason.revoked);
      await expectLater(
        container.read(authSession.notifier).credential(forceRenew: true)
            as Future<SessionCredential>,
        throwsA(isA<AuthRejected>()),
      );
      expect(rec.log.last, '#1 end auth rejected async');
    },
  );

  test('a renewal thrown away by a sign-out says cancelled', () async {
    final backend = FakeAuthBackend();
    final container = containerFor(signedInAs: ada, backend: backend);
    final notifier = container.read(authSession.notifier);
    final gate = backend.gate = Completer<void>();
    final waiting = notifier.credential(forceRenew: true);
    final failure = expectLater(
      waiting as Future<SessionCredential>,
      throwsA(isA<NotSignedIn>()),
    );
    await notifier.signOut();
    gate.complete();
    await failure;
    expect(
      rec.log.where((l) => l.contains('auth renew') || l.contains(' end ')),
      contains('#1 end auth cancelled async'),
    );
  });

  test('a restore that finds a session that has expired says expired', () {
    final time = TestTime();
    final session = AuthSession(
      backend: 'fake',
      credential: FakeCredential(
        id: 'fake-0',
        renewableUntil: time.now.subtract(const Duration(minutes: 1)),
      ),
      user: ada,
    );
    time.run(
      () => restoreAuth(
        AuthConfig(
          backend: FakeAuthBackend(),
          transport: noTransport,
          store: MemoryTokenStore(jsonEncode(session.toJson())),
        ),
      ),
    );
    expect(rec.log.last, '#1 end auth expired');
  });

  test('a restore the backend refuses says expired too', () {
    final session = fakeSession(ada);
    restoreAuth(
      AuthConfig(
        backend: FakeAuthBackend()..checkResult = SignOutReason.keyLost,
        transport: noTransport,
        store: MemoryTokenStore(jsonEncode(session.toJson())),
      ),
    );
    expect(rec.log.last, '#1 end auth expired');
  });

  test('a sign-out whose backend fails ends the span with the error', () async {
    final container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(
          AuthConfig(
            backend: _SignOutFails(),
            transport: noTransport,
            store: MemoryTokenStore(),
          ),
        ),
        authInitialState.overrideWithValue(SignedIn(fakeSession(ada))),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authSession.notifier).signOut();
    expect(rec.log, [
      '#1 start auth sign_out backend=fake scheme=fake',
      '#1 end auth error async error=Bad state: server down',
    ]);
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.user),
    );
  });

  test(
    'nothing that identifies anybody is ever told: no credential, id, e-mail, name or URL',
    () async {
      final time = TestTime();
      await time.run(() async {
        final backend = FakeAuthBackend(
          user: ada,
          credentialLifetime: lifetime,
        );
        final container = signedOutOn(backend);
        final notifier = container.read(authSession.notifier);
        await notifier.signIn(const TestSignIn());
        time.elapse(const Duration(minutes: 6));
        await (notifier.credential() as Future<SessionCredential>);
        backend.renewError = Exception('offline at https://sso.example.com');
        await expectLater(
          notifier.credential(forceRenew: true) as Future<SessionCredential>,
          throwsA(isA<AuthUnavailable>()),
        );
        backend.renewError = null;
        await notifier.signOut();
      });
      final text = rec.log.join('\n');
      for (final secret in [
        'fake-0',
        'fake-1',
        'fake-2',
        'ada-id',
        'ada@example.com',
        'Ada',
        'x-fake-credential',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(rec.log, isNotEmpty);
    },
  );

  test(
    'with no sink installed nothing is reported and everything works',
    () async {
      FespalierTelemetry.install(null);
      final container = signedOutOn(FakeAuthBackend(user: ada));
      final notifier = container.read(authSession.notifier);
      await notifier.signIn(const TestSignIn());
      await notifier.signOut();
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      expect(rec.log, isEmpty);
    },
  );

  test('a sink that throws costs a span, never the sign-in', () async {
    FespalierTelemetry.install(_Throwing());
    final container = signedOutOn(FakeAuthBackend(user: ada));
    await container.read(authSession.notifier).signIn(const TestSignIn());
    expect(container.read(authSession), isA<SignedIn>());
  });
}

final class _Throwing extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => throw StateError('sink');

  @override
  void end(Object? token, TelemetryEnd end) => throw StateError('sink');
}

final class _SchemeBackend extends StubBackend {
  _SchemeBackend() : super('device');

  @override
  String get scheme => 'signed';
}

final class _SignOutFails extends StubBackend {
  _SignOutFails();

  @override
  Future<void> signOut(AuthSession session) async =>
      throw StateError('server down');
}
