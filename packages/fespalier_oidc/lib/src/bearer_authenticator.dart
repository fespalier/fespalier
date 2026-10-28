import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'proof.dart';
import 'token_credential.dart';

/// Authenticates requests with the session's access token (since 0.21.0; it was the Authorizer's
/// own behaviour in `fespalier_auth`): `Authorization: Bearer <token>`, or, for a DPoP-bound token
/// (token type `DPoP`) and a [proof], `Authorization: DPoP <token>` and the proof's headers.
///
/// What a response means: a DPoP nonce challenge or clock correction (the proof says so) is a
/// `Resend`; a 401 whose `WWW-Authenticate` says `error="insufficient_user_authentication"`
/// (RFC 9470, since 0.25.0) is a `StepUp` with the `acr_values` and `max_age` it asks for, so the
/// user signs in again once (`OidcBackend.stepUp`) and the request goes out again; any other 401
/// is a `Renew`, so the session's single-flight renewal runs once and the request goes out again;
/// anything else stands. The authenticator never ends a session itself: only the token
/// endpoint's refusal does.
final class BearerAuthenticator implements RequestAuthenticator {
  /// An authenticator; [proof] is the DPoP proof maker, for DPoP-bound tokens.
  const BearerAuthenticator({this.proof});

  /// Makes the DPoP proof of each request, and reads the nonce of each response; null for
  /// bearer-only backends.
  final ProofOfPossession? proof;

  @override
  Future<Map<String, String>> headers(
    AuthSession session,
    TransportRequest request,
  ) async {
    final tokens = _tokens(session);
    if (!tokens.isDpop) {
      return {'Authorization': 'Bearer ${tokens.accessToken}'};
    }
    final proof = this.proof;
    if (proof == null) {
      throw StateError(
        'fespalier_oidc: the access token is DPoP-bound (token_type DPoP), but the backend has '
        'no proof of possession: pass proof: DpopProof.device() '
        '(package:fespalier_keypair_dpop) to the backend',
      );
    }
    final proofHeaders = await proof.headers(
      method: request.method,
      uri: request.uri,
      accessToken: tokens.accessToken,
    );
    return {'Authorization': 'DPoP ${tokens.accessToken}', ...proofHeaders};
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
    final proof = this.proof;
    if (proof != null &&
        _tokens(session).isDpop &&
        proof.onResponse(
          uri: request.uri,
          statusCode: statusCode,
          headers: headers,
          retried: retried,
        )) {
      return const Resend();
    }
    if (statusCode != 401) return const Accept();
    final challenge = StepUpChallenge.fromResponse(statusCode, headers);
    return challenge == null ? const Renew() : StepUp(challenge);
  }

  TokenCredential _tokens(AuthSession session) {
    final credential = session.credential;
    if (credential is! TokenCredential) {
      throw StateError(
        'fespalier_oidc: the session holds a ${credential.runtimeType}, not a TokenCredential: '
        'a BearerAuthenticator belongs to a backend that makes tokens',
      );
    }
    return credential;
  }
}
