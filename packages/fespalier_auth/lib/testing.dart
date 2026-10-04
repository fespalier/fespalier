/// Fakes for widget tests of an app that uses `fespalier_auth` (since 0.9.0): a backend with no
/// network, a proof of possession with no crypto, and `fakeAuth`, the overrides that sign a test
/// in or out.
///
/// ```dart
/// testWidgets('a member sees the orders', (tester) async {
///   await pumpRouter(
///     tester,
///     AppRoutes.router(initialLocation: '/orders'),
///     overrides: fakeAuth(signedInAs: const AuthUser(id: 'ada', roles: {'admin'})),
///   );
///   expect(currentLocation(tester), '/orders');
/// });
/// ```
///
/// Everything is deterministic: nothing waits for real time, tokens are numbered, and expiry reads
/// `clock.now()`, which a widget test's fake clock moves with `tester.pump(duration)`.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:http/http.dart' as http;

import 'fespalier_auth.dart';

/// A backend with no network (since 0.9.0). Every field can change between calls, and nothing
/// waits for time: tokens never expire unless [tokenLifetime] says so, and a test sets
/// [signInError], [refreshError] or [gate] to see a failure or a pending state.
final class FakeAuthBackend extends AuthBackend {
  /// A backend that signs in as [user]. [proof] makes its tokens DPoP-bound (a [FakeProof]).
  FakeAuthBackend({
    this.user = const AuthUser(id: 'user-1'),
    this.tokenLifetime,
    this.proof,
    this.name = 'fake',
  });

  /// Who `signIn` signs in as.
  AuthUser user;

  /// How long an access token lives, read against `clock.now()`; null: it never expires.
  Duration? tokenLifetime;

  @override
  final ProofOfPossession? proof;

  @override
  final String name;

  /// Thrown by the next `signIn`, then cleared: `AuthCancelled()`, `FieldErrors({...})`,
  /// `AuthRejected()`.
  Object? signInError;

  /// Thrown by every refresh until it is cleared: `AuthRejected()` ends the session, anything
  /// else keeps it.
  Object? refreshError;

  /// While set, `signIn` and `refresh` wait for it: a pending state a test can look at.
  Completer<void>? gate;

  /// How many sign-ins were asked for.
  int signIns = 0;

  /// How many refreshes were asked for.
  int refreshes = 0;

  /// How many sign-outs were asked for.
  int signOuts = 0;

  /// What each sign-in asked for.
  final List<SignInRequest> requests = [];

  int _issued = 0;

  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    signIns++;
    requests.add(request);
    await gate?.future;
    final error = signInError;
    if (error != null) {
      signInError = null;
      throw error;
    }
    return _issue(user: user, binding: await _binding());
  }

  @override
  Future<AuthSession> refresh(AuthSession session) async {
    refreshes++;
    await gate?.future;
    final error = refreshError;
    if (error != null) throw error;
    return session.copyWith(tokens: _tokens());
  }

  @override
  Future<void> signOut(AuthSession session) async {
    signOuts++;
  }

  Future<String?> _binding() async => await proof?.thumbprint();

  AuthSession _issue({required AuthUser user, String? binding}) => AuthSession(
    backend: name,
    tokens: _tokens(),
    user: user,
    binding: binding,
  );

  AuthTokens _tokens() {
    final n = ++_issued;
    final lifetime = tokenLifetime;
    return AuthTokens(
      accessToken: 'fake-access-$n',
      tokenType: proof != null ? 'DPoP' : 'Bearer',
      refreshToken: 'fake-refresh-$n',
      expiresAt: lifetime == null ? null : clock.now().add(lifetime),
    );
  }
}

/// A proof of possession with no crypto (since 0.9.0): `{'DPoP': 'fake-proof-<n> <METHOD> <htu>'}`,
/// then ` ath` with an access token and ` nonce=<n>` once a nonce was given. Set [challengeNext]
/// to make the next response look like a nonce challenge.
final class FakeProof implements ProofOfPossession {
  /// A proof whose key has the thumbprint [thumbprintValue].
  FakeProof({this.thumbprintValue = 'fake-thumbprint'});

  /// What [thumbprint] answers: the key a session is bound to.
  final String thumbprintValue;

  /// When true, the next [onResponse] asks for a retry with a new nonce, then clears it.
  bool challengeNext = false;

  /// The nonce the last challenge (or a `dpop-nonce` header) gave.
  String? nonce;

  /// The proofs made so far, in order.
  final List<String> proofs = [];

  /// How many nonce challenges were answered.
  int challenges = 0;

  /// How many times [reset] was called.
  int resets = 0;

  @override
  Future<String?> thumbprint() async => thumbprintValue;

  @override
  Future<Map<String, String>> headers({
    required String method,
    required Uri uri,
    String? accessToken,
  }) async {
    final n = proofs.length + 1;
    final proof =
        'fake-proof-$n $method ${uri.scheme}://${uri.authority}${uri.path}'
        '${accessToken == null ? '' : ' ath'}'
        '${nonce == null ? '' : ' nonce=$nonce'}';
    proofs.add(proof);
    return {'DPoP': proof};
  }

  @override
  bool onResponse({
    required Uri uri,
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  }) {
    final given = headers['dpop-nonce'];
    if (given != null) nonce = given;
    if (retried || !challengeNext) return false;
    challengeNext = false;
    nonce = 'nonce-${++challenges}';
    return true;
  }

  @override
  Future<void> reset() async {
    resets++;
    nonce = null;
  }
}

/// A session for [user], as [FakeAuthBackend] makes them (since 0.9.0): tokens `fake-access-0`
/// and `fake-refresh-0`, expiring after [lifetime] (never when null). Call it inside the test
/// body, where the fake clock starts.
AuthSession fakeSession(
  AuthUser user, {
  Duration? lifetime,
  String backend = 'fake',
  String? binding,
}) => AuthSession(
  backend: backend,
  tokens: AuthTokens(
    accessToken: 'fake-access-0',
    tokenType: binding == null ? 'Bearer' : 'DPoP',
    refreshToken: 'fake-refresh-0',
    expiresAt: lifetime == null ? null : clock.now().add(lifetime),
  ),
  user: user,
  binding: binding,
);

/// The overrides for `pumpRouter(overrides: ...)` (since 0.9.0): signed in as [signedInAs], or
/// signed out, on a [FakeAuthBackend] and a [MemoryTokenStore], so a guarded route renders (or
/// redirects to the sign-in page) with no `startup()` and no network.
///
/// Pass a [backend] to read its counters or to make it fail, a [store] to look at what is kept,
/// [apiOrigins] and a [client] (a `MockClient`) to test an API call, and [tokenLifetime] to age
/// the session with `tester.pump`. Call it inside the test body (the fake clock starts there).
List<Override> fakeAuth({
  AuthUser? signedInAs,
  FakeAuthBackend? backend,
  TokenStore? store,
  List<Uri> apiOrigins = const [],
  http.Client? client,
  Duration? tokenLifetime,
}) {
  final fake = backend ?? FakeAuthBackend(tokenLifetime: tokenLifetime);
  final config = AuthConfig(
    backend: fake,
    store: store ?? MemoryTokenStore(),
    apiOrigins: apiOrigins,
  );
  final proof = fake.proof;
  final state = signedInAs == null
      ? const SignedOut()
      : SignedIn(
          fakeSession(
            signedInAs,
            lifetime: tokenLifetime ?? fake.tokenLifetime,
            backend: fake.name,
            binding: proof is FakeProof ? proof.thumbprintValue : null,
          ),
        );
  return <Override>[
    authConfig.overrideWithValue(config),
    authInitialState.overrideWithValue(state),
    if (client != null) authBaseClient.overrideWithValue(client),
  ];
}
