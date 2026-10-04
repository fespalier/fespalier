import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:fespalier_sign_keypair/verify.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Someone the demo server knows.
class DemoUser {
  /// A user with [id], [name], [password] and [roles].
  const DemoUser(this.id, this.name, this.password, this.roles);

  /// The account's stable id.
  final String id;

  /// What the account is called.
  final String name;

  /// The password (a demo: it is the user name).
  final String password;

  /// What the account may do.
  final Set<String> roles;
}

/// The demo users: `ada` (an admin) and `bob`, whose passwords are their names.
const Map<String, DemoUser> demoUsers = {
  'ada': DemoUser('ada-id', 'Ada Example', 'ada', {'admin'}),
  'bob': DemoUser('bob-id', 'Bob Example', 'bob', {}),
};

class _Grant {
  _Grant(this.username, this.expiresAt, [this.jkt]);

  final String username;
  final DateTime expiresAt;

  /// The thumbprint of the key a DPoP-bound token belongs to (`cnf.jkt`), or null for a bearer one.
  final String? jkt;
}

class _Code {
  _Code({
    required this.username,
    required this.challenge,
    required this.redirectUri,
    required this.clientId,
    required this.nonce,
    required this.dpopJkt,
  });

  final String username;
  final String challenge;
  final String redirectUri;
  final String clientId;
  final String? nonce;

  /// The `dpop_jkt` of the authorization request: the code may only be exchanged with that key.
  final String? dpopJkt;
}

/// An in-process API on a `MockClient`, so the example runs and is tested with no network.
///
/// It has what an app talks to:
///
/// - `POST /auth/login`, `/auth/refresh` (every refresh token is good once: rotation) and
///   `/auth/logout`, for the username-and-password backend of `demo_backend.dart`;
/// - `GET /orders`, `/orders/{id}` and `/me`, which answer 401 to a token that is unknown or has
///   expired (a lifetime of [accessLifetime], read from `clock`, so a test's fake clock ages it);
/// - an OpenID Connect provider shaped like Keycloak, under `/oidc/protocol/openid-connect/`:
///   the authorization endpoint (answers the redirect a browser would follow), the token endpoint
///   (authorization code with the PKCE check, and refresh with rotation), revocation and end
///   session.
///
/// [latency] makes every answer take that long (zero in tests). With [trustAnyToken] the API
/// accepts any bearer token, for when the tokens come from a real Keycloak this server cannot ask.
///
/// With [requireDpop] the provider is a DPoP one (RFC 9449, `package:fespalier_sign_keypair`): the
/// token endpoint checks a proof on every call (`verifyDpopProof`), binds the code to the key of
/// `dpop_jkt`, issues `token_type: DPoP` tokens bound to the key of the proof, and refuses a refresh
/// token with a proof of another key; the API takes a DPoP-bound token only with the `DPoP` scheme and
/// a proof that has `ath`, is for that request, was not used before and is made by the key of the
/// token. Setting [apiNonce] makes the API ask for a nonce first (a `use_dpop_nonce` challenge), and
/// [clockSkew] puts this server's clock ahead of the device's, so a proof is refused as not active and
/// the answer carries a `Date` for the client to correct itself with. (Keycloak sends neither a nonce
/// nor a `Date`; both are in RFC 9449, and a server behind a proxy has the `Date`.)
class DemoServer {
  /// A server whose tokens live [accessLifetime].
  DemoServer({
    this.latency = Duration.zero,
    this.accessLifetime = const Duration(minutes: 5),
    this.trustAnyToken = false,
    this.requireDpop = false,
    this.clockSkew = Duration.zero,
    this.apiNonce,
  });

  /// The OpenID Connect issuer of the built-in provider.
  static const String issuer = 'https://api.example.com/oidc';

  /// How long every answer takes.
  final Duration latency;

  /// How long an access token is good, against `clock`.
  final Duration accessLifetime;

  /// Whether `/orders` accepts any bearer token.
  final bool trustAnyToken;

  /// Whether the built-in OpenID Connect provider issues DPoP-bound tokens and checks proofs.
  final bool requireDpop;

  /// How far this server's clock is ahead of `clock` (the device's).
  final Duration clockSkew;

  /// When set, the API asks for this nonce in every proof of a DPoP-bound token.
  String? apiNonce;

  final Map<String, _Grant> _access = {};
  final Map<String, _Grant> _refresh = {};
  final Set<String> _usedRefresh = {};
  final Map<String, _Code> _codes = {};
  final Set<String> _proofIds = {};
  int _issued = 0;

  /// The proofs the server checked and accepted, as `METHOD /path`, in order.
  final List<String> acceptedProofs = [];

  /// The proofs it refused, as the error it answered (`use_dpop_nonce`, `invalid_dpop_proof`, ...).
  final List<String> refusedProofs = [];

  /// How many proofs it refused because their `jti` had been seen: a proof is good once.
  int reusedProofs = 0;

  DateTime get _now => clock.now().add(clockSkew);

  /// Every request that reached the server, as `METHOD /path`, in order.
  final List<String> requests = [];

  /// How many sign-ins, refreshes and sign-outs it answered.
  int logins = 0, refreshes = 0, logouts = 0;

  /// The client to give `authBaseClient`.
  late final http.Client client = MockClient(_handle);

  /// Makes every access token the server has issued expire now, as if time had passed.
  void expireAccessTokens() => _access.clear();

  /// Forgets every refresh token, as if the realm's session had ended.
  void endSessions() => _refresh.clear();

  Future<http.Response> _handle(http.Request request) async {
    requests.add('${request.method} ${request.url.path}');
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final path = request.url.path;
    const oidc = '/oidc/protocol/openid-connect';
    return switch ((request.method, path)) {
      ('POST', '/auth/login') => _login(request),
      ('POST', '/auth/refresh') => _refreshDemo(request),
      ('POST', '/auth/logout') => _logout(request),
      ('GET', '/me') => _api(
        request,
        (u) => {'id': demoUsers[u]!.id, 'name': demoUsers[u]!.name},
      ),
      ('GET', '/orders') => _api(
        request,
        (u) => [for (final id in _orderIds(u)) _order(u, id)],
      ),
      ('GET', _) when path.startsWith('/orders/') => _order1(request),
      ('GET', '/oidc/.well-known/openid-configuration') => _json({
        'issuer': issuer,
        'authorization_endpoint': '$issuer/protocol/openid-connect/auth',
        'token_endpoint': '$issuer/protocol/openid-connect/token',
        'revocation_endpoint': '$issuer/protocol/openid-connect/revoke',
        'end_session_endpoint': '$issuer/protocol/openid-connect/logout',
        'dpop_signing_alg_values_supported': ['ES256'],
      }),
      ('GET', '$oidc/auth') => _authorize(request),
      ('POST', '$oidc/token') => _token(request),
      ('POST', '$oidc/revoke') => _revoke(request),
      ('GET', '$oidc/logout') => _endSession(request),
      _ => http.Response('not found', 404),
    };
  }

  // ------------------------------------------------------------------------- the demo backend

  http.Response _login(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final user = demoUsers[body['username']];
    if (user == null || user.password != body['password']) {
      return _json({'error': 'invalid_credentials'}, 401);
    }
    logins++;
    return _json(_demoTokens(body['username']! as String));
  }

  http.Response _refreshDemo(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final grant = _refresh.remove(body['refresh_token']);
    refreshes++;
    if (grant == null || !clock.now().isBefore(grant.expiresAt)) {
      return _json({'error': 'invalid_grant'}, 401);
    }
    return _json(_demoTokens(grant.username, withUser: false));
  }

  http.Response _logout(http.Request request) {
    logouts++;
    final body = jsonDecode(request.body) as Map<String, Object?>;
    _refresh.remove(body['refresh_token']);
    return http.Response('', 204);
  }

  Map<String, Object?> _demoTokens(String username, {bool withUser = true}) {
    final user = demoUsers[username]!;
    final access = 'demo-access-${++_issued}';
    final refresh = 'demo-refresh-${++_issued}';
    final now = clock.now();
    _access[access] = _Grant(username, now.add(accessLifetime));
    _refresh[refresh] = _Grant(username, now.add(const Duration(minutes: 30)));
    return {
      'access_token': access,
      'refresh_token': refresh,
      'expires_in': accessLifetime.inSeconds,
      if (withUser)
        'user': {
          'id': user.id,
          'name': user.name,
          'roles': user.roles.toList(),
        },
    };
  }

  // --------------------------------------------------------------------------------- the API

  /// The user a request's token belongs to (a `String`), or the 401 to answer it with.
  Object _authenticate(http.Request request) {
    final header = request.headers['Authorization'];
    final space = header?.indexOf(' ') ?? -1;
    if (header == null || space < 0) return _unauthorized('Bearer');
    final scheme = header.substring(0, space);
    final token = header.substring(space + 1);
    if (trustAnyToken && token.isNotEmpty) return 'ada';
    final grant = _access[token];
    if (grant == null || !clock.now().isBefore(grant.expiresAt)) {
      return _unauthorized(scheme.toLowerCase() == 'dpop' ? 'DPoP' : 'Bearer');
    }
    final jkt = grant.jkt;
    if (jkt == null) return grant.username; // a bearer token
    // A DPoP-bound token: the DPoP scheme, and a proof of the key it is bound to (RFC 9449 section 7.1).
    if (scheme.toLowerCase() != 'dpop') return _unauthorized('Bearer');
    final proof = request.headers['DPoP'];
    if (proof == null) return _unauthorized('DPoP');
    try {
      verifyDpopProof(
        proof,
        method: request.method,
        uri: request.url,
        accessToken: token,
        nonce: apiNonce,
        thumbprint: jkt,
        now: _now,
      );
    } on DpopProofInvalid catch (e) {
      if (e.message.startsWith('nonce is')) {
        refusedProofs.add('use_dpop_nonce');
        return _unauthorized(
          'DPoP',
          error: 'use_dpop_nonce',
          description: 'Resource server requires nonce in DPoP proof',
          headers: {'dpop-nonce': apiNonce!},
        );
      }
      refusedProofs.add('invalid_dpop_proof');
      return _unauthorized(
        'DPoP',
        error: 'invalid_dpop_proof',
        description: e.message,
        // The Date lets a client whose clock is off correct itself (RFC 9110 section 6.6.1).
        headers: e.message.startsWith('iat is')
            ? {'date': _httpDate(_now)}
            : const {},
      );
    }
    if (!_remember(proof)) {
      refusedProofs.add('invalid_dpop_proof');
      return _unauthorized(
        'DPoP',
        error: 'invalid_dpop_proof',
        description: 'DPoP proof has already been used',
      );
    }
    acceptedProofs.add('${request.method} ${request.url.path}');
    return grant.username;
  }

  /// Whether [proof] is new: a proof is good once (its `jti`). A proof that was used before is
  /// counted in [reusedProofs].
  bool _remember(String proof) {
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(proof.split('.')[1]))),
    );
    final fresh = _proofIds.add(
      (claims as Map<String, Object?>)['jti']! as String,
    );
    if (!fresh) reusedProofs++;
    return fresh;
  }

  http.Response _unauthorized(
    String scheme, {
    String error = 'invalid_token',
    String? description,
    Map<String, String> headers = const {},
  }) => http.Response(
    jsonEncode({'error': error}),
    401,
    headers: {
      'www-authenticate': scheme == 'DPoP'
          ? 'DPoP algs="ES256", error="$error"'
                '${description == null ? '' : ', error_description="$description"'}'
          : 'Bearer error="invalid_token"',
      'content-type': 'application/json',
      ...headers,
    },
  );

  http.Response _api(
    http.Request request,
    Object Function(String username) answer,
  ) {
    final auth = _authenticate(request);
    if (auth is http.Response) return auth;
    return _json(answer(auth as String), 200, {
      // A server that asks for nonces keeps handing out the current one (RFC 9449 section 8.2).
      'dpop-nonce': ?apiNonce,
    });
  }

  /// An HTTP date, as `Date` carries it (RFC 9110 section 5.6.7).
  static String _httpDate(DateTime time) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int n) => n.toString().padLeft(2, '0');
    final u = time.toUtc();
    return '${days[u.weekday - 1]}, ${two(u.day)} ${months[u.month - 1]} ${u.year} '
        '${two(u.hour)}:${two(u.minute)}:${two(u.second)} GMT';
  }

  Iterable<int> _orderIds(String username) =>
      username == 'ada' ? [1, 2, 3] : [4, 5];

  Map<String, Object?> _order(String username, int id) => {
    'id': id,
    'title': '${demoUsers[username]!.name}: order $id',
  };

  http.Response _order1(http.Request request) {
    final id = int.tryParse(request.url.pathSegments.last);
    return _api(
      request,
      (user) => id != null && _orderIds(user).contains(id)
          ? _order(user, id)
          : {'error': 'not_found'},
    );
  }

  // ------------------------------------------------------------------- OpenID Connect, Keycloak's shape

  /// What a browser does with the authorization URL: signs [DemoUser] `ada` in (or the `login_hint`)
  /// and answers the redirect to the app, with the code, the state and `iss` (RFC 9207).
  http.Response _authorize(http.Request request) {
    final p = request.url.queryParameters;
    final username = demoUsers.containsKey(p['login_hint'])
        ? p['login_hint']!
        : 'ada';
    final redirect = p['redirect_uri']!;
    if (p['prompt'] == 'none') {
      return _redirect(redirect, {
        'error': 'login_required',
        'state': p['state'],
        'iss': issuer,
      });
    }
    final code = 'demo-code-${++_issued}';
    _codes[code] = _Code(
      username: username,
      challenge: p['code_challenge'] ?? '',
      redirectUri: redirect,
      clientId: p['client_id'] ?? '',
      nonce: p['nonce'],
      dpopJkt: p['dpop_jkt'],
    );
    return _redirect(redirect, {
      'code': code,
      'state': p['state'],
      'iss': issuer,
    });
  }

  http.Response _redirect(String to, Map<String, String?> params) {
    final uri = Uri.parse(to).replace(
      queryParameters: {
        for (final e in params.entries)
          if (e.value != null) e.key: e.value!,
      },
    );
    return http.Response('', 302, headers: {'location': uri.toString()});
  }

  http.Response _token(http.Request request) {
    final form = request.bodyFields;
    DecodedDpopProof? proof;
    if (requireDpop) {
      final checked = _checkTokenProof(request);
      if (checked is http.Response) return checked;
      proof = checked as DecodedDpopProof;
    }
    return switch (form['grant_type']) {
      'authorization_code' => _exchange(form, proof),
      'refresh_token' => _rotate(form, proof),
      _ => _oauthError('unsupported_grant_type', 'Unsupported grant_type'),
    };
  }

  /// The proof of a token request, or the 400 to answer it with (RFC 9449 section 5; Keycloak's
  /// descriptions where it has them).
  Object _checkTokenProof(http.Request request) {
    final header = request.headers['DPoP'];
    if (header == null) {
      refusedProofs.add('invalid_request');
      return _oauthError('invalid_request', 'DPoP proof is missing');
    }
    final DecodedDpopProof decoded;
    try {
      decoded = verifyDpopProof(
        header,
        method: request.method,
        uri: request.url,
        now: _now,
      );
    } on DpopProofInvalid catch (e) {
      refusedProofs.add('invalid_dpop_proof');
      final late = e.message.startsWith('iat is');
      return _oauthError(
        'invalid_dpop_proof',
        late ? 'DPoP proof is not active' : e.message,
        headers: late ? {'date': _httpDate(_now)} : const {},
      );
    }
    if (!_remember(header)) {
      refusedProofs.add('invalid_request');
      return _oauthError('invalid_request', 'DPoP proof has already been used');
    }
    acceptedProofs.add('${request.method} ${request.url.path}');
    return decoded;
  }

  http.Response _exchange(Map<String, String> form, DecodedDpopProof? proof) {
    final code = _codes.remove(form['code']);
    if (code == null) return _oauthError('invalid_grant', 'Code not valid');
    if (form['redirect_uri'] != code.redirectUri) {
      return _oauthError('invalid_grant', 'Incorrect redirect_uri');
    }
    if (proof != null &&
        code.dpopJkt != null &&
        code.dpopJkt != proof.thumbprint) {
      return _oauthError(
        'invalid_request',
        'DPoP Proof public key thumbprint does not match dpop_jkt',
      );
    }
    final verifier = form['code_verifier'];
    if (verifier == null) {
      return _oauthError('invalid_grant', 'PKCE code verifier not specified');
    }
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    if (challenge != code.challenge) {
      return _oauthError(
        'invalid_grant',
        'PKCE verification failed: Code mismatch',
      );
    }
    logins++;
    return _json(
      _oidcTokens(
        code.username,
        code.clientId,
        nonce: code.nonce,
        jkt: proof?.thumbprint,
      ),
    );
  }

  http.Response _rotate(Map<String, String> form, DecodedDpopProof? proof) {
    final token = form['refresh_token'];
    if (_usedRefresh.contains(token)) {
      return _oauthError(
        'invalid_grant',
        'Maximum allowed refresh token reuse exceeded',
      );
    }
    final bound = _refresh[token]?.jkt;
    if (bound != null && bound != proof?.thumbprint) {
      // The token is not used up: only the holder of the key can use it (RFC 9449 section 5).
      return _oauthError(
        'invalid_grant',
        "DPoP confirmation doesn't match DPoP proof",
      );
    }
    final grant = _refresh.remove(token);
    refreshes++;
    if (grant == null) {
      return _oauthError('invalid_grant', 'Invalid refresh token');
    }
    _usedRefresh.add(token!);
    if (!clock.now().isBefore(grant.expiresAt)) {
      return _oauthError('invalid_grant', 'Token is not active');
    }
    return _json(
      _oidcTokens(
        grant.username,
        form['client_id'] ?? '',
        jkt: proof?.thumbprint,
      ),
    );
  }

  http.Response _revoke(http.Request request) {
    logouts++;
    _refresh.remove(request.bodyFields['token']);
    return http.Response('', 200);
  }

  http.Response _endSession(http.Request request) {
    final back = request.url.queryParameters['post_logout_redirect_uri'];
    return back == null ? http.Response('', 200) : _redirect(back, {});
  }

  Map<String, Object?> _oidcTokens(
    String username,
    String clientId, {
    String? nonce,
    String? jkt,
  }) {
    final user = demoUsers[username]!;
    final now = clock.now();
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    final access = _jwt({
      'iss': issuer,
      'sub': user.id,
      'preferred_username': username,
      'jti': 'a${++_issued}',
      'iat': seconds,
      'exp': seconds + accessLifetime.inSeconds,
      'realm_access': {
        'roles': ['offline_access', ...user.roles],
      },
      // A DPoP-bound token says which key it belongs to (RFC 9449 section 6.1).
      'cnf': ?(jkt == null ? null : {'jkt': jkt}),
    });
    final refresh = 'demo-refresh-${++_issued}';
    _access[access] = _Grant(username, now.add(accessLifetime), jkt);
    _refresh[refresh] = _Grant(
      username,
      now.add(const Duration(minutes: 30)),
      jkt,
    );
    return {
      'access_token': access,
      'expires_in': accessLifetime.inSeconds,
      'refresh_expires_in': 1800,
      'refresh_token': refresh,
      'token_type': jkt == null ? 'Bearer' : 'DPoP',
      'id_token': _jwt({
        'iss': issuer,
        'aud': clientId,
        'sub': user.id,
        'name': user.name,
        'preferred_username': username,
        'email': '$username@example.com',
        'nonce': ?nonce,
        'iat': seconds,
        'exp': seconds + accessLifetime.inSeconds,
      }),
      'scope': 'openid profile email',
    };
  }

  http.Response _oauthError(
    String error,
    String description, {
    Map<String, String> headers = const {},
  }) => _json({'error': error, 'error_description': description}, 400, headers);

  http.Response _json(
    Object body, [
    int status = 200,
    Map<String, String> headers = const {},
  ]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json', ...headers},
  );

  /// A JWT with no signature, built at run time: the demo's tokens are not secrets.
  static String _jwt(Map<String, Object?> claims) {
    String part(Object json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    return '${part({'alg': 'none', 'typ': 'JWT'})}.${part(claims)}.demo';
  }
}
