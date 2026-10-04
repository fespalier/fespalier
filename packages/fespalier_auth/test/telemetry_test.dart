// What fespalier_auth tells the installed sink (since 0.9.0): one span per restore, sign-in,
// refresh and sign-out, with the backend's constant name and nothing that identifies anybody.
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
      AuthConfig(backend: backend, store: MemoryTokenStore()),
    );
    final container = ProviderContainer(overrides: result as List<Override>);
    addTearDown(container.dispose);
    return container;
  }

  test('restore: a span at start-up, none when nothing was stored', () {
    signedOutOn(FakeAuthBackend());
    expect(rec.log, ['#1 start auth restore backend=fake', '#1 end auth none']);
  });

  test('sign-in, then sign-out: ok and async', () async {
    final container = signedOutOn(FakeAuthBackend(user: ada));
    rec.log.clear();
    final notifier = container.read(authSession.notifier);
    await notifier.signIn(const PasswordSignIn(username: 'ada', password: 'x'));
    await notifier.signOut();
    expect(rec.log, [
      '#2 start auth sign_in backend=fake',
      '#2 end auth ok async',
      '#3 start auth sign_out backend=fake',
      '#3 end auth ok async',
    ]);
  });

  test('a refresh says what asked for it', () async {
    final time = TestTime();
    await time.run(() async {
      final backend = FakeAuthBackend(tokenLifetime: lifetime);
      final container = containerFor(
        signedInAs: ada,
        backend: backend,
        tokenLifetime: lifetime,
      );
      final notifier = container.read(authSession.notifier);
      time.elapse(const Duration(minutes: 6));
      await (notifier.tokens() as Future<AuthTokens>);
      await (notifier.tokens(rejected: 'fake-access-1') as Future<AuthTokens>);
      await (notifier.tokens(forceRefresh: true) as Future<AuthTokens>);
      expect(rec.log, [
        '#1 start auth refresh backend=fake trigger=expired',
        '#1 end auth ok async',
        '#2 start auth refresh backend=fake trigger=unauthorized',
        '#2 end auth ok async',
        '#3 start auth refresh backend=fake trigger=forced',
        '#3 end auth ok async',
      ]);
    });
  });

  test('a shared refresh is one span, however many wait', () async {
    final time = TestTime();
    await time.run(() async {
      final backend = FakeAuthBackend(tokenLifetime: lifetime);
      final container = containerFor(
        signedInAs: ada,
        backend: backend,
        tokenLifetime: lifetime,
      );
      final notifier = container.read(authSession.notifier);
      time.elapse(const Duration(minutes: 6));
      await Future.wait([
        notifier.tokens() as Future<AuthTokens>,
        notifier.tokens() as Future<AuthTokens>,
        notifier.tokens() as Future<AuthTokens>,
      ]);
      expect(
        rec.log.where((l) => l.contains('start auth refresh')),
        hasLength(1),
      );
    });
  });

  test('a good token asks for nothing: no span', () {
    final container = containerFor(signedInAs: ada);
    container.read(authSession.notifier).tokens();
    expect(rec.log, isEmpty);
  });

  test('a backend that binds its tokens is marked dpop', () async {
    final container = signedOutOn(FakeAuthBackend(proof: FakeProof()));
    await container
        .read(authSession.notifier)
        .signIn(const PasswordSignIn(username: 'a', password: 'b'));
    expect(rec.log.first, '#1 start auth restore backend=fake dpop');
    expect(rec.log[2], '#2 start auth sign_in backend=fake dpop');
  });

  test('rejected, cancelled and error are told apart', () async {
    final backend = FakeAuthBackend();
    final container = signedOutOn(backend);
    final notifier = container.read(authSession.notifier);
    rec.log.clear();
    const request = PasswordSignIn(username: 'a', password: 'b');

    backend.signInError = const FieldErrors({'password': 'Wrong'});
    await expectLater(notifier.signIn(request), throwsA(isA<FieldErrors>()));
    backend.signInError = const AuthRejected();
    await expectLater(notifier.signIn(request), throwsA(isA<AuthRejected>()));
    backend.signInError = const AuthCancelled();
    await expectLater(notifier.signIn(request), throwsA(isA<AuthCancelled>()));
    backend.signInError = StateError('the network is down');
    await expectLater(notifier.signIn(request), throwsStateError);

    expect(rec.log, [
      '#2 start auth sign_in backend=fake',
      '#2 end auth rejected async',
      '#3 start auth sign_in backend=fake',
      '#3 end auth rejected async',
      '#4 start auth sign_in backend=fake',
      '#4 end auth cancelled async',
      '#5 start auth sign_in backend=fake',
      '#5 end auth error async error=Bad state: the network is down',
    ]);
  });

  test(
    'a refresh that is refused is rejected; one that cannot run is an error',
    () async {
      final time = TestTime();
      await time.run(() async {
        final backend = FakeAuthBackend(tokenLifetime: lifetime);
        final container = containerFor(
          signedInAs: ada,
          backend: backend,
          tokenLifetime: lifetime,
        );
        final notifier = container.read(authSession.notifier);
        time.elapse(const Duration(minutes: 6));
        backend.refreshError = Exception('offline');
        await expectLater(
          notifier.tokens() as Future<AuthTokens>,
          throwsA(isA<AuthUnavailable>()),
        );
        backend.refreshError = const AuthRejected();
        await expectLater(
          notifier.tokens() as Future<AuthTokens>,
          throwsA(isA<AuthRejected>()),
        );
        expect(rec.log.where((l) => l.contains(' end ')), [
          '#1 end auth error async error=ClientException: fespalier_auth: couldn\'t refresh the session: Exception: offline',
          '#2 end auth rejected async',
        ]);
      });
    },
  );

  test('a restore that finds a session that has expired says expired', () {
    final time = TestTime();
    final session = AuthSession(
      backend: 'fake',
      tokens: AuthTokens(
        accessToken: 'a',
        refreshToken: 'r',
        refreshExpiresAt: time.now.subtract(const Duration(minutes: 1)),
      ),
      user: ada,
    );
    time.run(
      () => restoreAuth(
        AuthConfig(
          backend: FakeAuthBackend(),
          store: MemoryTokenStore(jsonEncode(session.toJson())),
        ),
      ),
    );
    expect(rec.log.last, '#1 end auth expired');
  });

  test(
    'nothing that identifies anybody is ever told: no token, id, e-mail, name or URL',
    () async {
      final time = TestTime();
      await time.run(() async {
        final backend = FakeAuthBackend(user: ada, tokenLifetime: lifetime);
        final container = signedOutOn(backend);
        final notifier = container.read(authSession.notifier);
        await notifier.signIn(
          const PasswordSignIn(username: 'ada', password: 'hunter2'),
        );
        time.elapse(const Duration(minutes: 6));
        await (notifier.tokens() as Future<AuthTokens>);
        await notifier.signOut();
      });
      final text = rec.log.join('\n');
      for (final secret in [
        'fake-access',
        'fake-refresh',
        'ada',
        'Ada',
        'example.com',
        'hunter2',
        'http',
      ]) {
        expect(text, isNot(contains(secret)));
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
      await notifier.signIn(const PasswordSignIn(username: 'a', password: 'b'));
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
    await container
        .read(authSession.notifier)
        .signIn(const PasswordSignIn(username: 'a', password: 'b'));
    expect(container.read(authSession), isA<SignedIn>());
  });
}

final class _Throwing extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => throw StateError('sink');

  @override
  void end(Object? token, TelemetryEnd end) => throw StateError('sink');
}
