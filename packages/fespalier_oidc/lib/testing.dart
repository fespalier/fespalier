/// Fakes for tests of an app that uses `fespalier_oidc` (since 0.21.0; they were in
/// `package:fespalier_auth/testing.dart`): a proof of possession with no crypto, and a token
/// session for a widget test.
///
/// For the core's fakes (`fakeAuth`, `FakeAuthBackend`), see `package:fespalier_auth/testing.dart`.
library;

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

import 'fespalier_oidc.dart';

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

/// A session of the `oidc` backend for [user], with tokens `fake-access-0` and `fake-refresh-0`
/// expiring after [lifetime] (never when null), DPoP-bound when [binding] is given. Call it
/// inside the test body, where the fake clock starts.
AuthSession fakeTokenSession(
  AuthUser user, {
  Duration? lifetime,
  String backend = 'oidc',
  String? binding,
}) => AuthSession(
  backend: backend,
  credential: TokenCredential(
    accessToken: 'fake-access-0',
    tokenType: binding == null ? 'Bearer' : 'DPoP',
    refreshToken: 'fake-refresh-0',
    expiresAt: lifetime == null ? null : clock.now().add(lifetime),
    jkt: binding,
  ),
  user: user,
);
