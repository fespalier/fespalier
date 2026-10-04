import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sign_keypair/flutter_sign_keypair.dart'
    show SoftwareKeyStore;
import 'package:http_parser/http_parser.dart';

import 'jose.dart';
import 'signer.dart';

/// What `DpopProof.device` does where there is no secure element: the web, Windows, Linux and
/// Fuchsia (since 0.9.0).
enum DpopFallback {
  /// Throw `DpopUnavailable` (the default): a library that promises tokens bound to a device
  /// must not quietly give you tokens bound to nothing.
  refuse,

  /// A software key (`SoftwareDpopSigner`): its scalar is in memory, and on the web it does not
  /// survive a reload (pass `softwareStore` to keep it).
  software,

  /// No DPoP: `device()` returns null, and the tokens are plain bearer tokens. The client must
  /// not require DPoP-bound tokens.
  bearer,
}

/// There is no secure element on this platform, and `DpopFallback.refuse` was asked for
/// (since 0.9.0). Thrown by `DpopProof.device`, so from `startup()` or `authSetup()`, early and
/// loud.
final class DpopUnavailable extends UnsupportedError {
  /// The error for [platform] (`the web`, `Windows`, `Linux` or `Fuchsia`).
  DpopUnavailable(String platform)
    : super(
        'fespalier_sign_keypair: $platform has no secure element for a DPoP key. Pass '
        'fallback: DpopFallback.software for a software key (on the web it does not survive a '
        'reload), or DpopFallback.bearer to send bearer tokens (the client must not require '
        'DPoP-bound tokens)',
      );
}

/// DPoP (RFC 9449) for `fespalier_auth` (since 0.9.0): give it to the backend,
/// `OidcBackend(proof: DpopProof.device())`.
///
/// A proof is a JWT signed with the device key (`typ` `dpop+jwt`, `alg` `ES256`, the public key
/// in the header) that says which request it is for (`htm`, `htu`), when (`iat`), once (`jti`),
/// for which access token (`ath`) and, when the server asked, with its latest `nonce`. The
/// tokens the server issues are bound to the key (`cnf.jkt`), so a stolen access or refresh
/// token is useless without it.
///
/// - **One signature per request**, made by the secure element; nothing is cached between
///   requests (a proof is single-use), and no timer or listener is started.
/// - **Nonces.** A `DPoP-Nonce` from any response is kept for its origin. A challenge
///   (`use_dpop_nonce`) is answered once, with a new proof.
/// - **Clock.** `iat` follows the device clock. When the server refuses a proof as not active,
///   and the response has a `Date` header that differs from the device clock by more than
///   [clockCorrectionThreshold], the difference is applied to every later `iat` and the request
///   is sent once more. A server that sends no `Date` (Keycloak sends none) cannot correct a
///   wrong clock: set the clock.
final class DpopProof implements ProofOfPossession {
  /// A proof maker for [signer].
  ///
  /// [rotateKeyOnSignOut] deletes the key at sign-out, so the next sign-in makes a new one
  /// (an old refresh token, even a stolen one, is useless then). [random] is for a test.
  DpopProof({
    required this.signer,
    this.rotateKeyOnSignOut = true,
    this.clockCorrectionThreshold = const Duration(seconds: 5),
    Random? random,
    // A private field cannot be a named initializing formal.
    // ignore: prefer_initializing_formals
  }) : _random = random;

  /// The key id of the hardware key, in the secure element and in `SoftwareKeyStore`s.
  static const String defaultKeyId = defaultDpopKeyId;

  /// This device's proof maker, for `OidcBackend(proof: ...)`: the hardware key on Android, iOS
  /// and macOS; elsewhere what [fallback] says. Returns null for `DpopFallback.bearer` on a
  /// platform with no secure element.
  ///
  /// [requireHardware] makes a device whose secure element is missing (the iOS simulator has
  /// only the keychain) fail at its first use with a `SecureSignerException`; where there is no
  /// secure element at all it is [DpopUnavailable] unless [fallback] is `bearer`.
  /// [softwareStore] keeps the software key (`DpopFallback.software`).
  static DpopProof? device({
    DpopFallback fallback = DpopFallback.refuse,
    String keyId = defaultKeyId,
    bool requireHardware = false,
    SoftwareKeyStore? softwareStore,
  }) => deviceFor(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    fallback: fallback,
    keyId: keyId,
    requireHardware: requireHardware,
    softwareStore: softwareStore,
  );

  /// [device] for the given platform, so a test can see each one.
  @visibleForTesting
  static DpopProof? deviceFor({
    required bool isWeb,
    required TargetPlatform platform,
    DpopFallback fallback = DpopFallback.refuse,
    String keyId = defaultKeyId,
    bool requireHardware = false,
    SoftwareKeyStore? softwareStore,
  }) {
    final native =
        !isWeb &&
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS ||
            platform == TargetPlatform.macOS);
    if (native) {
      return DpopProof(
        signer: SignKeypairSigner(
          keyId: keyId,
          requireHardware: requireHardware,
        ),
      );
    }
    final name = isWeb
        ? 'the web'
        : switch (platform) {
            TargetPlatform.windows => 'Windows',
            TargetPlatform.linux => 'Linux',
            TargetPlatform.fuchsia => 'Fuchsia',
            _ => platform.name,
          };
    switch (fallback) {
      case DpopFallback.bearer:
        return null;
      case DpopFallback.software when !requireHardware:
        return DpopProof(
          signer: SoftwareDpopSigner(keyId: keyId, store: softwareStore),
        );
      case DpopFallback.software:
      case DpopFallback.refuse:
        throw DpopUnavailable(name);
    }
  }

  /// What signs.
  final DpopSigner signer;

  /// Whether sign-out deletes the key (the next sign-in makes a new one).
  final bool rotateKeyOnSignOut;

  /// How far the `Date` header may be from the device clock before it is believed.
  final Duration clockCorrectionThreshold;

  Random? _random;
  Random get _rng => _random ??= Random.secure();

  final Map<String, String> _nonces = <String, String>{};
  Duration _offset = Duration.zero;
  ({String x, String y, String encoded})? _header;

  /// The correction applied to `iat` (server time minus device time): zero until a server's
  /// `Date` said otherwise, and again after [reset].
  Duration get clockOffset => _offset;

  /// The public key as a JWK, for a backend that registers devices itself.
  Future<Map<String, String>> publicJwk() => signer.publicJwk();

  @override
  Future<String?> thumbprint() async => jwkThumbprint(await signer.publicJwk());

  /// One proof JWT for [method] [uri], with `ath` when [accessToken] is given, for a request
  /// made without `fespalier_auth`'s clients.
  Future<String> proof({
    required String method,
    required Uri uri,
    String? accessToken,
  }) async {
    final jwk = await signer.publicJwk();
    final cached = _header;
    final String header;
    if (cached != null && cached.x == jwk['x'] && cached.y == jwk['y']) {
      header = cached.encoded;
    } else {
      header = base64UrlNoPadding(
        utf8.encode(
          jsonEncode(<String, Object>{
            'typ': 'dpop+jwt',
            'alg': 'ES256',
            'jwk': <String, String>{
              'crv': 'P-256',
              'kty': 'EC',
              'x': jwk['x']!,
              'y': jwk['y']!,
            },
          }),
        ),
      );
      _header = (x: jwk['x']!, y: jwk['y']!, encoded: header);
    }
    final nonce = _nonces[_origin(uri)];
    final claims = base64UrlNoPadding(
      utf8.encode(
        jsonEncode(<String, Object>{
          'jti': base64UrlNoPadding(
            List<int>.generate(16, (_) => _rng.nextInt(256)),
          ),
          'htm': method,
          'htu': dpopHtu(uri),
          'iat': clock.now().add(_offset).millisecondsSinceEpoch ~/ 1000,
          'ath': ?(accessToken == null ? null : accessTokenHash(accessToken)),
          'nonce': ?nonce,
        }),
      ),
    );
    final signingInput = '$header.$claims';
    final signature = await signer.sign(
      Uint8List.fromList(utf8.encode(signingInput)),
    );
    if (signature.length != 64) {
      throw StateError(
        'fespalier_sign_keypair: the signer returned ${signature.length} bytes, not the '
        '64-byte r||s signature that ES256 needs',
      );
    }
    return '$signingInput.${base64UrlNoPadding(signature)}';
  }

  @override
  Future<Map<String, String>> headers({
    required String method,
    required Uri uri,
    String? accessToken,
  }) async => <String, String>{
    'DPoP': await proof(method: method, uri: uri, accessToken: accessToken),
  };

  @override
  bool onResponse({
    required Uri uri,
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  }) {
    final nonce = headers['dpop-nonce'];
    if (nonce != null && nonce.isNotEmpty) _nonces[_origin(uri)] = nonce;
    if (retried) return false;
    final error = _error(statusCode, headers, body);
    if (error == null) return false;
    if (error.code == 'use_dpop_nonce') {
      return nonce != null && nonce.isNotEmpty;
    }
    if (error.clock) return _correctClock(headers['date']);
    return false;
  }

  @override
  Future<void> reset() async {
    _nonces.clear();
    _offset = Duration.zero;
    _header = null;
    if (rotateKeyOnSignOut) await signer.deleteKey();
  }

  /// Applies the `Date` header when it says the device clock is off, and returns whether the
  /// request is worth sending again.
  bool _correctClock(String? date) {
    if (date == null) return false;
    final DateTime server;
    try {
      server = parseHttpDate(date);
    } on FormatException {
      return false;
    }
    final offset = server.difference(clock.now());
    final threshold = clockCorrectionThreshold.abs();
    // The device clock is right (within the threshold), or this is the correction already made.
    if (offset.abs() <= threshold || (offset - _offset).abs() <= threshold) {
      return false;
    }
    _offset = offset;
    return true;
  }

  /// The DPoP problem a response reports, if it reports one: the OAuth error code, and whether
  /// it is about the proof's time.
  ({String code, bool clock})? _error(
    int statusCode,
    Map<String, String> headers,
    String? body,
  ) {
    if (statusCode == 401) {
      final params = _dpopChallenge(headers['www-authenticate']);
      if (params == null) return null;
      final code = params['error'];
      if (code == null) return null;
      // An RFC 9449 resource server says invalid_dpop_proof; Keycloak's says invalid_token
      // for every problem. Either one with a skewed Date is worth one more proof.
      return (
        code: code,
        clock: code == 'invalid_dpop_proof' || code == 'invalid_token',
      );
    }
    if (statusCode == 400 && body != null) {
      final Object? json;
      try {
        json = jsonDecode(body);
      } on FormatException {
        return null;
      }
      if (json is! Map<String, Object?>) return null;
      final code = json['error'];
      if (code is! String) return null;
      final description = json['error_description'];
      return (
        code: code,
        // RFC 9449 section 5: invalid_dpop_proof. Keycloak 26.8.0 says invalid_request with
        // the description "DPoP proof is not active" (read from a live server).
        clock:
            code == 'invalid_dpop_proof' ||
            (code == 'invalid_request' &&
                description is String &&
                description.contains('DPoP proof is not active')),
      );
    }
    return null;
  }

  /// The parameters of the `DPoP` challenge in a `WWW-Authenticate` value, or null when there is
  /// none. The value may carry several challenges (`Bearer realm="a", DPoP error="b"`).
  static Map<String, String>? _dpopChallenge(String? value) {
    if (value == null) return null;
    final start = RegExp(
      r'(?:^|,)\s*DPoP(?=\s|$)',
      caseSensitive: false,
    ).firstMatch(value);
    if (start == null) return null;
    var rest = value.substring(start.end);
    // The next challenge starts at a scheme, which has no `=` after its first word.
    final next = RegExp(
      r'(?:^|,)\s*(?:Bearer|Basic|Digest|Negotiate)(?=\s|$)',
      caseSensitive: false,
    ).firstMatch(rest);
    if (next != null) rest = rest.substring(0, next.start);
    final params = <String, String>{};
    for (final m in RegExp(
      r'([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))',
    ).allMatches(rest)) {
      params[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3)!;
    }
    return params;
  }

  /// `scheme://host:port`, the key of the nonces: an authorization server and a resource server
  /// keep their own.
  static String _origin(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final defaultPort = switch (scheme) {
      'http' => 80,
      'https' => 443,
      _ => null,
    };
    final port = uri.hasPort ? uri.port : defaultPort;
    return '$scheme://${uri.host.toLowerCase()}${port == null ? '' : ':$port'}';
  }
}
