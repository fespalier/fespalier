/// Fakes for widget tests of an app that uses `fespalier_auth` (since 0.9.0): a backend with no
/// network, an authenticator with no crypto, and `fakeAuth`, the overrides that sign a test in or
/// out.
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
/// Everything is deterministic: nothing waits for real time, credentials are numbered, and
/// expiry reads `clock.now()`, which a widget test's fake clock moves with `tester.pump(duration)`.
/// Since 0.21.0 the fakes know the core only: a `FakeCredential`, not a token. A token backend's
/// fakes (`FakeProof`) are in `package:fespalier_oidc/testing.dart`.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';

import 'fespalier_auth.dart';

/// A credential with no secret in it (since 0.21.0): an [id] that numbers it (`fake-1`), and the
/// dates the core reads.
final class FakeCredential implements SessionCredential {
  /// A credential named [id].
  const FakeCredential({
    required this.id,
    this.expiresAt,
    this.renewableUntil,
    this.renewable = true,
  });

  /// Reads what [toJson] wrote.
  factory FakeCredential.fromJson(Map<String, Object?> json) {
    DateTime? date(String key) {
      final text = json[key];
      return text is String ? DateTime.parse(text) : null;
    }

    final id = json['id'];
    if (id is! String) {
      throw const FormatException('FakeCredential: "id" is not a string');
    }
    return FakeCredential(
      id: id,
      expiresAt: date('expiresAt'),
      renewableUntil: date('renewableUntil'),
      renewable: json['renewable'] != false,
    );
  }

  /// What names it: `fake-0` for a session made by [fakeSession], `fake-<n>` for the n-th a
  /// [FakeAuthBackend] issued.
  final String id;

  @override
  final DateTime? expiresAt;

  @override
  final DateTime? renewableUntil;

  @override
  final bool renewable;

  @override
  Map<String, Object?> toJson() => {
    'id': id,
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'renewableUntil': renewableUntil?.toUtc().toIso8601String(),
    'renewable': renewable,
  };

  @override
  bool operator ==(Object other) =>
      other is FakeCredential &&
      other.id == id &&
      other.expiresAt == expiresAt &&
      other.renewableUntil == renewableUntil &&
      other.renewable == renewable;

  @override
  int get hashCode => Object.hash(id, expiresAt, renewableUntil, renewable);

  @override
  String toString() => 'FakeCredential($id)';
}

/// What a [FakeAuthenticator] decides a response means.
typedef FakeVerdict =
    AuthVerdict Function(
      AuthSession session,
      TransportRequest request,
      int statusCode,
      Map<String, String> headers,
      String? body,
      bool retried,
    );

/// An authenticator with no crypto (since 0.21.0): it adds `x-fake-credential: <id>#<n>`, where
/// `n` counts the sends it was asked about (so every send is visibly signed afresh), and by
/// default answers `StepUp` to a 401 with an RFC 9470 challenge
/// (`StepUpChallenge.fromResponse`, since 0.25.0), `Renew` to any other 401 and `Accept` to
/// anything else. Set [verdict] to say otherwise, and [refuse] to make a send fail to sign. Every
/// request it was asked to sign is in [signed], with its body.
final class FakeAuthenticator implements RequestAuthenticator {
  /// An authenticator that adds [headerName].
  FakeAuthenticator({
    this.headerName = 'x-fake-credential',
    this.verdict,
    this.refuse,
  });

  /// The header it adds.
  final String headerName;

  /// What a response means; null: a 401 is a `StepUp` when it carries a step-up challenge, else
  /// a `Renew`; anything else is `Accept`.
  FakeVerdict? verdict;

  /// What `headers` throws for a request instead of signing it, when it answers one (since
  /// 0.25.0): a `ProofDeclined` plays a user who declined a prompt. Null, or a null answer, signs.
  Object? Function(TransportRequest request)? refuse;

  /// A request `headers` was asked about, in order.
  final List<TransportRequest> signed = [];

  /// The responses `judge` was asked about, as `statusCode`, in order.
  final List<int> judged = [];

  @override
  Future<Map<String, String>> headers(
    AuthSession session,
    TransportRequest request,
  ) async {
    signed.add(request);
    final refusal = refuse?.call(request);
    if (refusal != null) throw refusal;
    final credential = session.credential;
    final id = credential is FakeCredential ? credential.id : '$credential';
    return {headerName: '$id#${signed.length}'};
  }

  @override
  AuthVerdict judge(
    AuthSession session,
    TransportRequest request, {
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  }) {
    judged.add(statusCode);
    final custom = verdict;
    if (custom != null) {
      return custom(session, request, statusCode, headers, body, retried);
    }
    if (statusCode != 401) return const Accept();
    final challenge = StepUpChallenge.fromResponse(statusCode, headers);
    return challenge != null ? StepUp(challenge) : const Renew();
  }
}

/// A backend with no network (since 0.9.0). Every field can change between calls, and nothing
/// waits for time: credentials never expire unless [credentialLifetime] says so, and a test sets
/// [signInError], [renewError] or [gate] to see a failure or a pending state.
final class FakeAuthBackend extends AuthBackend {
  /// A backend that signs in as [user].
  FakeAuthBackend({
    this.user = const AuthUser(id: 'user-1'),
    this.credentialLifetime,
    this.name = 'fake',
    this.renewAhead = Duration.zero,
    FakeAuthenticator? authenticator,
  }) : authenticator = authenticator ?? FakeAuthenticator();

  /// Who `signIn` signs in as.
  AuthUser user;

  /// What `signIn` and `stepUp` give as `AuthSession.authenticatedAt` (since 0.25.0); null lets
  /// the core stamp the time of the call.
  DateTime? authTime;

  /// Who `stepUp` answers for (since 0.25.0); null: the session's own user.
  AuthUser? stepUpUser;

  /// How long a credential lives, read against `clock.now()`; null: it never expires.
  Duration? credentialLifetime;

  @override
  final String name;

  @override
  String get scheme => 'fake';

  @override
  final Duration renewAhead;

  @override
  final FakeAuthenticator authenticator;

  /// Thrown by the next `signIn`, then cleared: `AuthCancelled()`, `FieldErrors({...})`,
  /// `AuthRejected()`.
  Object? signInError;

  /// Thrown by every renewal until it is cleared: `AuthRejected()` ends the session (as
  /// `expired`; `AuthEnded(reason)` gives another), anything else keeps it.
  Object? renewError;

  /// Thrown by every step-up until it is cleared (since 0.25.0): `AuthCancelled()`,
  /// `AuthRejected()`, or anything else for a step-up that could not ask.
  Object? stepUpError;

  /// What `check` answers at a restore: null keeps the session.
  SignOutReason? checkResult;

  /// While set, `signIn`, `renew` and `stepUp` wait for it: a pending state a test can look at.
  Completer<void>? gate;

  /// How many sign-ins were asked for.
  int signIns = 0;

  /// How many renewals were asked for.
  int renewals = 0;

  /// The `hint` of each renewal, in order.
  final List<Object?> hints = [];

  /// How many step-ups were asked for (since 0.25.0).
  int stepUps = 0;

  /// The challenge of each step-up, in order (since 0.25.0).
  final List<StepUpChallenge> stepUpChallenges = [];

  /// How many sign-outs were asked for.
  int signOuts = 0;

  /// How many times `discard` was called.
  int discards = 0;

  /// What each sign-in asked for.
  final List<SignInRequest> requests = [];

  int _issued = 0;

  @override
  FakeCredential readCredential(Map<String, Object?> json) =>
      FakeCredential.fromJson(json);

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
    return AuthSession(
      backend: name,
      credential: _issue(),
      user: user,
      authenticatedAt: authTime,
    );
  }

  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) async {
    renewals++;
    hints.add(hint);
    await gate?.future;
    final error = renewError;
    if (error != null) throw error;
    return session.copyWith(credential: _issue());
  }

  @override
  Future<AuthSession> stepUp(
    AuthSession session,
    StepUpChallenge challenge,
  ) async {
    stepUps++;
    stepUpChallenges.add(challenge);
    await gate?.future;
    final error = stepUpError;
    if (error != null) throw error;
    return AuthSession(
      backend: name,
      credential: _issue(),
      user: stepUpUser ?? session.user,
      authenticatedAt: authTime,
    );
  }

  @override
  FutureOr<SignOutReason?> check(AuthSession session) => checkResult;

  @override
  Future<void> signOut(AuthSession session) async {
    signOuts++;
  }

  @override
  Future<void> discard(AuthSession session) async {
    discards++;
  }

  FakeCredential _issue() {
    final lifetime = credentialLifetime;
    return FakeCredential(
      id: 'fake-${++_issued}',
      expiresAt: lifetime == null ? null : clock.now().add(lifetime),
    );
  }
}

/// A session for [user], as [FakeAuthBackend] makes them (since 0.9.0): the credential
/// `fake-0`, expiring after [lifetime] (never when null), authenticated at [authenticatedAt]
/// (since 0.25.0; null: unknown, which `requireFreshAuth` reads as too old). Call it inside the
/// test body, where the fake clock starts.
AuthSession fakeSession(
  AuthUser user, {
  Duration? lifetime,
  String backend = 'fake',
  DateTime? authenticatedAt,
}) => AuthSession(
  backend: backend,
  credential: FakeCredential(
    id: 'fake-0',
    expiresAt: lifetime == null ? null : clock.now().add(lifetime),
  ),
  user: user,
  authenticatedAt: authenticatedAt,
);

/// The overrides for `pumpRouter(overrides: ...)` (since 0.9.0): signed in as [signedInAs], or
/// signed out, on a [FakeAuthBackend] and a [MemoryTokenStore], so a guarded route renders (or
/// redirects to the sign-in page) with no `startup()` and no network.
///
/// Pass a [backend] to read its counters or to make it fail, a [store] to look at what is kept,
/// [apiOrigins] and a [transport] (a `FakeTransport`) to test an API call, and
/// [credentialLifetime] to age the session with `tester.pump`, and [authenticatedAt] (since
/// 0.25.0; `clock.now()` for a fresh one) for a route behind `requireFreshAuth`. Call it inside
/// the test body (the fake clock starts there).
List<Override> fakeAuth({
  AuthUser? signedInAs,
  FakeAuthBackend? backend,
  TokenStore? store,
  List<Uri> apiOrigins = const [],
  HttpTransport? transport,
  Duration? credentialLifetime,
  DateTime? authenticatedAt,
}) {
  final fake =
      backend ?? FakeAuthBackend(credentialLifetime: credentialLifetime);
  final config = AuthConfig(
    backend: fake,
    transport: transport ?? FakeTransport((_, _) => fakeResponse(200)),
    store: store ?? MemoryTokenStore(),
    apiOrigins: apiOrigins,
  );
  final state = signedInAs == null
      ? const SignedOut()
      : SignedIn(
          fakeSession(
            signedInAs,
            lifetime: credentialLifetime ?? fake.credentialLifetime,
            backend: fake.name,
            authenticatedAt: authenticatedAt,
          ),
        );
  return <Override>[
    authConfig.overrideWithValue(config),
    authInitialState.overrideWithValue(state),
  ];
}
