import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../backend.dart';
import '../errors.dart';
import '../jwt.dart';
import '../session.dart';
import 'endpoints.dart';
import 'exception.dart';
import 'pkce.dart';
import 'roles.dart';

/// Opens [authorizationUrl] in a browser and completes with the redirect to [redirectUri], the
/// whole URL (since 0.9.0). Throw `AuthCancelled` when the user closed it.
///
/// No plugin sits in `fespalier_auth` for this: an app that uses Firebase never links one.
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
/// over `package:http` (since 0.9.0), with Keycloak's defaults.
///
/// ```dart
/// OidcBackend(
///   issuer: Uri.parse('https://sso.example.com/realms/shop'),
///   clientId: 'shop-app',
///   redirectUri: Uri.parse('com.example.shop:/callback'),
///   endpoints: OidcEndpoints.keycloak(Uri.parse('https://sso.example.com/realms/shop')),
///   openBrowser: openBrowser,
/// )
/// ```
///
/// It owns the token exchange and the refresh, which is what makes single-flight refresh,
/// refresh-token rotation and DPoP on the token endpoint possible. It does not verify the ID
/// token's signature (OpenID Connect Core 3.1.3.7: the token came from the token endpoint over
/// TLS) but checks its issuer, audience and nonce. It makes no request with a timeout of its own
/// (a timer): pass a [client] that times out if you want one. Confidential clients (a
/// `client_secret`) are out of scope: a mobile or web app is a public client.
final class OidcBackend extends AuthBackend {
  /// A backend for the client [clientId] of the issuer [issuer]. The browser is [openBrowser];
  /// [redirectUri] is what the provider sends it back to (registered with the client).
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
    http.Client? client,
    this.proof,
    @visibleForTesting Random? random,
  }) : _endpoints = endpoints,
       _roles = roles ?? keycloakRoles(clientId),
       _client = client ?? http.Client(),
       _random = random ?? Random.secure();

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

  @override
  final ProofOfPossession? proof;

  final Set<String> Function(Map<String, Object?>, Map<String, Object?>) _roles;
  final http.Client _client;
  final Random _random;
  OidcEndpoints? _endpoints;
  Future<OidcEndpoints>? _discovering;

  @override
  String get name => 'oidc';

  Future<OidcEndpoints> _resolve() async {
    final known = _endpoints;
    if (known != null) return known;
    final running = _discovering ??= OidcEndpoints.discover(
      issuer,
      client: _client,
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

  /// BrowserSignIn only: the browser step, then the code exchange.
  @override
  Future<AuthSession> signIn(SignInRequest request) async {
    if (request is! BrowserSignIn) {
      throw UnsupportedError(
        'fespalier_auth: OidcBackend signs in with BrowserSignIn, not ${request.runtimeType}',
      );
    }
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
    final code = _code(redirect.queryParameters, state);
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

  /// Checks the redirect and returns its code.
  String _code(Map<String, String> params, String state) {
    if (params['state'] != state) {
      throw const OidcException(
        "the redirect's state does not match the sign-in that opened it",
      );
    }
    final error = params['error'];
    if (error != null) {
      if (error == 'access_denied') throw const AuthCancelled();
      final description = params['error_description'];
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

  /// New tokens for [session]. A refusal that ends the session (`invalid_grant`, `invalid_client`,
  /// `unauthorized_client`, a DPoP proof the provider rejects for good) is `AuthRejected`; a
  /// socket error, a timeout and a 5xx are `AuthUnavailable`, and the session stays. The refresh
  /// token the provider returns replaces the old one (rotation), and one it leaves out keeps it.
  @override
  Future<AuthSession> refresh(AuthSession session) async {
    final refreshToken = session.tokens.refreshToken;
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
    final token = session.tokens.refreshToken;
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
        'id_token_hint': ?session.tokens.idToken,
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
    while (true) {
      final proofHeaders =
          await proof?.headers(method: 'POST', uri: uri) ??
          const <String, String>{};
      final response = await _client.post(
        uri,
        headers: {'Accept': 'application/json', ...proofHeaders},
        body: form,
      );
      final again = proof?.onResponse(
        uri: uri,
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.body,
        retried: retried,
      );
      if (again == true && !retried) {
        retried = true;
        continue;
      }
      return _Answer(response.statusCode, response.body);
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
    final tokens = AuthTokens(
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
    );
    final idToken = tokens.idToken;
    final idClaims = idToken == null
        ? const <String, Object?>{}
        : _checkIdToken(idToken, nonce);
    if (previous != null && idToken == null) {
      return previous.copyWith(tokens: previous.tokens.merge(tokens));
    }
    final accessClaims =
        unverifiedJwtClaims(access) ?? const <String, Object?>{};
    final AuthUser user;
    try {
      user = AuthUser.fromClaims({
        ...accessClaims,
        ...idClaims,
      }, roles: _roles(accessClaims, idClaims));
    } on FormatException {
      throw const OidcException('the tokens carry no "sub" claim');
    }
    return AuthSession(
      backend: name,
      tokens: previous == null ? tokens : previous.tokens.merge(tokens),
      user: user,
      // The key the tokens are bound to, when the provider bound them (token_type DPoP).
      binding: tokens.isDpop ? await proof?.thumbprint() : null,
    );
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
