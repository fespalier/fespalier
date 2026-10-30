import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'bearer_authenticator.dart';
import 'endpoints.dart';
import 'exception.dart';
import 'jwt.dart';
import 'pkce.dart';
import 'proof.dart';
import 'roles.dart';
import 'sign_in.dart';
import 'token_credential.dart';
import 'user.dart';

/// Opens [authorizationUrl] in a browser and completes with the redirect to [redirectUri], the
/// whole URL (since 0.9.0). Throw `AuthCancelled` when the user closed it.
///
/// No plugin sits in `fespalier_oidc` for this: an app that uses Firebase never links one.
/// `flutter_web_auth_2` is the usual implementation:
///
/// ```dart
/// Future<Uri> openBrowser(Uri url, Uri redirect) async {
///   try {
///     return Uri.parse(await FlutterWebAuth2.authenticate(
///       url: url.toString(),
///       callbackUrlScheme: redirect.scheme,
///       options: const FlutterWebAuth2Options(preferEphemeral: true),
///     ));
///   } on PlatformException catch (e) {
///     if (e.code == 'CANCELED') throw const AuthCancelled();
///     rethrow;
///   }
/// }
/// ```
typedef OpenBrowser =
    Future<Uri> Function(Uri authorizationUrl, Uri redirectUri);

/// OpenID Connect: the authorization code flow with PKCE (S256) for a public client, in pure Dart
/// over an `HttpTransport` (since 0.9.0, in `fespalier_auth`; `fespalier_oidc` since 0.21.0),
/// with Keycloak's defaults.
///
/// ```dart
/// OidcBackend(
///   issuer: Uri.parse('https://sso.example.com/realms/shop'),
///   clientId: 'shop-app',
///   redirectUri: Uri.parse('com.example.shop:/callback'),
///   endpoints: OidcEndpoints.keycloak(Uri.parse('https://sso.example.com/realms/shop')),
///   openBrowser: openBrowser,
///   transport: transport,
/// )
/// ```
///
/// It owns the token exchange and the refresh, which is what makes single-flight refresh,
/// refresh-token rotation and DPoP on the token endpoint possible. It does not verify the ID
/// token's signature (OpenID Connect Core 3.1.3.7: the token came from the token endpoint over
/// TLS) but checks its issuer, audience and nonce. It makes no request with a timeout of its own
/// (a timer): pass a [transport] over a client that times out if you want one. Confidential clients (a
/// `client_secret`) are out of scope: a mobile or web app is a public client.
final class OidcBackend extends AuthBackend {
  /// A backend for the client [clientId] of the issuer [issuer]. The browser is [openBrowser];
  /// [redirectUri] is what the provider sends it back to (registered with the client). The
  /// token, discovery and revocation calls go through [transport], which should be the one of
  /// `AuthConfig.transport` (a session is not attached to them: the token endpoint is not the
  /// API).
  ///
  /// [endpoints] is [OidcEndpoints.keycloak] or your own; null discovers them at the first sign-in
  /// or refresh and keeps them in memory. [bindCodeToKey] sends `dpop_jkt`, which binds the code to
  /// the key, when there is a [proof]. [roles] reads the user's roles from the claims
  /// (`keycloakRoles(clientId)` by default). [postLogoutRedirectUri] is where [endBrowserSession]
  /// ends up.
  OidcBackend({
    required this.issuer,
    required this.clientId,
    required this.redirectUri,
    required this.openBrowser,
    this.scopes = const ['openid', 'profile', 'email'],
    OidcEndpoints? endpoints,
    this.postLogoutRedirectUri,
    this.bindCodeToKey = true,
    Set<String> Function(Map<String, Object?>, Map<String, Object?>)? roles,
    required this.transport,
    this.proof,
    this.renewAhead = const Duration(seconds: 30),
    @visibleForTesting Random? random,
  }) : _endpoints = endpoints,
       _roles = roles ?? keycloakRoles(clientId),
       _random = random ?? Random.secure(),
       authenticator = BearerAuthenticator(proof: proof);

  /// The provider's issuer, e.g. `https://sso.example.com/realms/shop`.
  final Uri issuer;

  /// The public client's id.
  final String clientId;

  /// Where the browser is sent back to: a custom scheme (`com.example.shop:/callback`), or a page.
  final Uri redirectUri;

  /// Opens the authorization URL and returns the redirect.
  final OpenBrowser openBrowser;

  /// The scopes asked for.
  final List<String> scopes;

  /// Where [endBrowserSession] ends up; falls back to [redirectUri].
  final Uri? postLogoutRedirectUri;

  /// Whether the authorization request carries `dpop_jkt` (Keycloak 26.4 and later accepts it).
  final bool bindCodeToKey;

  /// What the token, discovery and revocation calls are sent through.
  final HttpTransport transport;

  /// Makes the DPoP proofs, and binds the tokens to its key; null for bearer tokens.
  final ProofOfPossession? proof;

  /// How long before an access token expires it is renewed (lazily, by the next request); the
  /// 30 seconds `AuthConfig.leeway` had.
  @override
  final Duration renewAhead;

  @override
  final BearerAuthenticator authenticator;

  final Set<String> Function(Map<String, Object?>, Map<String, Object?>) _roles;
  final Random _random;
  OidcEndpoints? _endpoints;
  Future<OidcEndpoints>? _discovering;

  @override
  String get name => 'oidc';

  @override
  String get scheme => proof == null ? 'bearer' : 'dpop';

  @override
  TokenCredential readCredential(Map<String, Object?> json) =>
      TokenCredential.fromJson(json);

  Future<OidcEndpoints> _resolve() async {
    final known = _endpoints;
    if (known != null) return known;
    final running = _discovering ??= OidcEndpoints.discover(
      issuer,
      transport: transport,
    );
    try {
      final found = await running;
      final algs = found.dpopAlgorithms;
      if (proof != null && algs != null && !algs.contains('ES256')) {
        throw OidcException(
          'the server does not accept ES256 DPoP proofs '
          '(dpop_signing_alg_values_supported: ${algs.join(', ')})',
        );
      }
      return _endpoints = found;
    } finally {
      // A failure is not remembered: the next sign-in or refresh asks again.
      if (_endpoints == null) _discovering = null;
    }
  }

  /// BrowserSignIn only: the browser step, then the code exchange. The session's
  /// `AuthSession.authenticatedAt` is the ID token's `auth_time` when it has one (since 0.25.0).
  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! BrowserSignIn) {
      throw UnsupportedError(
        'fespalier_oidc: OidcBackend signs in with BrowserSignIn, not ${request.runtimeType}',
      );
    }
    return _browserSession(request);
  }

  /// Step-up (RFC 9470, since 0.25.0): the browser sign-in again, for the same user, with what
  /// [challenge] asks: `acr_values` and `max_age` when it names them, `prompt=login` when it
  /// names neither (a re-proof as it is), and `login_hint` with the user's e-mail address when
  /// it is known. The new tokens replace the old ones (a new refresh token too), and
  /// `AuthSession.authenticatedAt` is the new ID token's `auth_time` (the core stamps the time of
  /// the step-up when there is none).
  ///
  /// `AuthCancelled` when the user closed the browser, `AuthRejected` when the provider answered
  /// the authorization with an error (`access_denied` is a cancel), an `OidcException` for
  /// anything else it could not check. The session stays as it was in every case.
  @override
  Future<AuthSession> stepUp(
    AuthSession session,
    StepUpChallenge challenge,
  ) async {
    final maxAge = challenge.maxAge;
    final next = await _browserSession(
      BrowserSignIn(
        loginHint: session.user.email,
        prompt: challenge.acrValues.isEmpty && maxAge == null ? 'login' : null,
        parameters: {
          if (challenge.acrValues.isNotEmpty)
            'acr_values': challenge.acrValues.join(' '),
          if (maxAge != null) 'max_age': '${maxAge.inSeconds}',
        },
      ),
      stepUp: true,
    );
    return next;
  }

  Future<AuthSession> _browserSession(
    BrowserSignIn request, {
    bool stepUp = false,
  }) async {
    final endpoints = await _resolve();
    final pkce = Pkce.generate(_random);
    final state = randomToken(_random, 16);
    final nonce = randomToken(_random, 16);
    final thumbprint = proof != null && bindCodeToKey
        ? await proof!.thumbprint()
        : null;
    final authorization = endpoints.authorization.replace(
      queryParameters: {
        ...endpoints.authorization.queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri.toString(),
        'scope': scopes.join(' '),
        'state': state,
        'nonce': nonce,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
        if (request.loginHint != null) 'login_hint': request.loginHint!,
        if (request.prompt != null) 'prompt': request.prompt!,
        'dpop_jkt': ?thumbprint,
        ...request.parameters,
      },
    );
    final redirect = await openBrowser(authorization, redirectUri);
    final code = _code(redirect.queryParameters, state, stepUp: stepUp);
    final answer = await _post(endpoints.token, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri.toString(),
      'client_id': clientId,
      'code_verifier': pkce.verifier,
    });
    if (answer.status != 200) throw _refused(answer);
    return _session(answer, nonce: nonce);
  }

  /// Checks the redirect and returns its code. During a step-up, an error the provider answered
  /// (an `unmet_authentication_requirements`, a `login_required`) is an `AuthRejected`: the
  /// session stays and the request's 401 stands.
  String _code(
    Map<String, String> params,
    String state, {
    bool stepUp = false,
  }) {
    if (params['state'] != state) {
      throw const OidcException(
        "the redirect's state does not match the sign-in that opened it",
      );
    }
    final error = params['error'];
    if (error != null) {
      if (error == 'access_denied') throw const AuthCancelled();
      final description = params['error_description'];
      if (stepUp) throw AuthRejected(error, description);
      throw OidcException(
        'the server answered the sign-in with error $error'
        '${description == null ? '' : ': $description'}',
      );
    }
    final iss = params['iss'];
    if (iss != null && _same(iss, issuer.toString()) == false) {
      throw OidcException('the redirect comes from $iss, not $issuer');
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const OidcException('the redirect has no code');
    }
    return code;
  }

  /// New tokens for [session] ([hint] is not used). A refusal that ends the session (`invalid_grant`, `invalid_client`,
  /// `unauthorized_client`, a DPoP proof the provider rejects for good) is `AuthRejected`; a
  /// socket error, a timeout and a 5xx are `AuthUnavailable`, and the session stays. The refresh
  /// token the provider returns replaces the old one (rotation), and one it leaves out keeps it.
  @override
  Future<AuthSession> renew(AuthSession session, {Object? hint}) async {
    final refreshToken = _tokens(session).refreshToken;
    if (refreshToken == null) {
      throw const AuthRejected('invalid_grant', 'there is no refresh token');
    }
    final _Answer answer;
    try {
      final endpoints = await _resolve();
      answer = await _post(endpoints.token, {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      });
    } on OidcException {
      rethrow;
    } on Object catch (error) {
      throw AuthUnavailable(error);
    }
    if (answer.status == 200) return _session(answer, previous: session);
    final error = answer.error;
    if (answer.status >= 500) {
      throw AuthUnavailable(OidcException(_refusal(answer)));
    }
    if (const {
      'invalid_grant',
      'invalid_client',
      'unauthorized_client',
      'invalid_dpop_proof',
      'use_dpop_nonce',
    }.contains(error)) {
      throw AuthRejected(error!, answer.description);
    }
    throw _refused(answer);
  }

  /// RFC 7009 revocation of the refresh token, when the provider has an endpoint. Keycloak ends
  /// the whole session with it. Best effort: the local sign-out has already happened.
  @override
  Future<void> signOut(AuthSession session) async {
    final token = _tokens(session).refreshToken;
    if (token == null) return;
    final endpoints = await _resolve();
    final revocation = endpoints.revocation;
    if (revocation == null) return;
    await _post(revocation, {
      'token': token,
      'token_type_hint': 'refresh_token',
      'client_id': clientId,
    });
  }

  /// Opens the end-session endpoint (`id_token_hint`, `client_id`, `post_logout_redirect_uri`) in
  /// the browser, to end the browser's single-sign-on session too. Optional: with an ephemeral
  /// browser session (`preferEphemeral: true`) there is none to end, and [signOut] already revoked
  /// the refresh token. A closed browser is not an error.
  Future<void> endBrowserSession(AuthSession session) async {
    final endpoints = await _resolve();
    final endSession = endpoints.endSession;
    if (endSession == null) return;
    final back = postLogoutRedirectUri ?? redirectUri;
    final url = endSession.replace(
      queryParameters: {
        ...endSession.queryParameters,
        'id_token_hint': ?_tokens(session).idToken,
        'client_id': clientId,
        'post_logout_redirect_uri': back.toString(),
      },
    );
    try {
      await openBrowser(url, back);
    } on AuthCancelled {
      // Nothing to end.
    }
  }

  /// A form POST to [uri], with a DPoP proof when there is one. A nonce challenge or a clock
  /// correction is answered once with a fresh proof; a code survives that (Keycloak 26.8 keeps it).
  Future<_Answer> _post(Uri uri, Map<String, String> form) async {
    var retried = false;
    final body = Uint8List.fromList(
      utf8.encode(Uri(queryParameters: form).query),
    );
    while (true) {
      final proofHeaders =
          await proof?.headers(method: 'POST', uri: uri) ??
          const <String, String>{};
      final response = await transport.send(
        TransportRequest(
          method: 'POST',
          uri: uri,
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
            ...proofHeaders,
          },
          body: body,
        ),
      );
      final text = utf8.decode(await response.bytes(), allowMalformed: true);
      final again = proof?.onResponse(
        uri: uri,
        statusCode: response.statusCode,
        headers: response.headers,
        body: text,
        retried: retried,
      );
      if (again == true && !retried) {
        retried = true;
        continue;
      }
      return _Answer(response.statusCode, text);
    }
  }

  /// The tokens and the user of a 200 answer. [nonce] is given at sign-in, to check the ID token's.
  Future<AuthSession> _session(
    _Answer answer, {
    String? nonce,
    AuthSession? previous,
  }) async {
    final json = answer.json;
    final access = json['access_token'];
    if (access is! String || access.isEmpty) {
      throw const OidcException(
        "the token endpoint's answer has no access_token",
      );
    }
    String? text(String key) =>
        json[key] is String ? json[key] as String : null;
    int? seconds(String key) =>
        json[key] is num ? (json[key] as num).toInt() : null;
    final now = clock.now();
    final expiresIn = seconds('expires_in');
    final refreshExpiresIn = seconds('refresh_expires_in');
    final tokens = TokenCredential(
      accessToken: access,
      tokenType: text('token_type') ?? 'Bearer',
      refreshToken: text('refresh_token'),
      idToken: text('id_token'),
      expiresAt: expiresIn == null
          ? null
          : now.add(Duration(seconds: expiresIn)),
      // 0 means the refresh token never expires (an offline token on some providers).
      refreshExpiresAt: refreshExpiresIn != null && refreshExpiresIn > 0
          ? now.add(Duration(seconds: refreshExpiresIn))
          : null,
      scope: text('scope'),
      // The key the tokens are bound to, when the provider bound them (token_type DPoP).
      jkt: text('token_type')?.toLowerCase() == 'dpop'
          ? await proof?.thumbprint()
          : null,
    );
    final idToken = tokens.idToken;
    final idClaims = idToken == null
        ? const <String, Object?>{}
        : _checkIdToken(idToken, nonce);
    if (previous != null && idToken == null) {
      return previous.copyWith(credential: _tokens(previous).merge(tokens));
    }
    final accessClaims =
        unverifiedJwtClaims(access) ?? const <String, Object?>{};
    final authTime = _authTime(idClaims) ?? _authTime(accessClaims);
    final AuthUser user;
    try {
      user = userFromClaims({
        ...accessClaims,
        ...idClaims,
      }, roles: _roles(accessClaims, idClaims));
    } on FormatException {
      throw const OidcException('the tokens carry no "sub" claim');
    }
    return AuthSession(
      backend: name,
      credential: previous == null ? tokens : _tokens(previous).merge(tokens),
      user: user,
      authenticatedAt: authTime ?? previous?.authenticatedAt,
    );
  }

  /// The `auth_time` claim (seconds since the epoch), as a UTC time; null when absent.
  static DateTime? _authTime(Map<String, Object?> claims) {
    final value = claims['auth_time'];
    if (value is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
      isUtc: true,
    );
  }

  /// The device key the tokens are bound to must still be the one the proofs are made with.
  ///
  /// Synchronous for a session that is not bound to a key (and for one bound with no proof to
  /// check it against), so `restoreAuth` stays synchronous over a synchronous store.
  @override
  FutureOr<SignOutReason?> check(AuthSession session) {
    final jkt = _tokens(session).jkt;
    if (jkt == null) return null;
    final proof = this.proof;
    if (proof == null) return SignOutReason.keyLost;
    return proof.thumbprint().then<SignOutReason?>(
      (current) => current == jkt ? null : SignOutReason.keyLost,
    );
  }

  /// Forgets the proof's nonces and clock correction, and (`DpopProof`) its key.
  @override
  Future<void> discard(AuthSession session) async => proof?.reset();

  TokenCredential _tokens(AuthSession session) {
    final credential = session.credential;
    if (credential is! TokenCredential) {
      throw StateError(
        'fespalier_oidc: the session holds a ${credential.runtimeType}, not a TokenCredential',
      );
    }
    return credential;
  }

  /// The ID token's claims, after the checks OpenID Connect Core 3.1.3.7 asks of a client that got
  /// the token straight from the token endpoint: issuer, audience and (at sign-in) nonce. The
  /// signature is not verified.
  Map<String, Object?> _checkIdToken(String idToken, String? nonce) {
    final claims = unverifiedJwtClaims(idToken);
    if (claims == null) throw const OidcException('the ID token is not a JWT');
    final iss = claims['iss'];
    if (iss is! String || !_same(iss, issuer.toString())) {
      throw OidcException('the ID token was issued by $iss, not $issuer');
    }
    final aud = claims['aud'];
    final audiences = aud is String
        ? [aud]
        : (aud is List<Object?> ? aud : const <Object?>[]);
    if (!audiences.contains(clientId)) {
      throw OidcException(
        'the ID token is for ${aud is List ? aud.join(', ') : aud}, not for $clientId',
      );
    }
    if (nonce != null && claims['nonce'] != nonce) {
      throw const OidcException(
        "the ID token's nonce does not match the sign-in",
      );
    }
    return claims;
  }

  /// The error of a token endpoint answer that is not one of the ones that end a session.
  OidcException _refused(_Answer answer) => OidcException(_refusal(answer));

  String _refusal(_Answer answer) {
    final description = answer.description;
    return 'the token endpoint answered HTTP ${answer.status}: '
        '${answer.error ?? 'no OAuth error in the answer'}'
        '${description == null ? '' : ': $description'}';
  }

  static bool _same(String a, String b) =>
      a.replaceFirst(RegExp(r'/+$'), '') == b.replaceFirst(RegExp(r'/+$'), '');
}

/// A token endpoint's answer: its status and body.
final class _Answer {
  _Answer(this.status, this.body);

  final int status;
  final String body;

  Map<String, Object?> get json {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      // Not JSON: no fields.
    }
    return const <String, Object?>{};
  }

  String? get error => json['error'] is String ? json['error'] as String : null;

  String? get description => json['error_description'] is String
      ? json['error_description'] as String
      : null;
}
