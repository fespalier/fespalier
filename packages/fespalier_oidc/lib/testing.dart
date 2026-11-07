/// Fakes for tests of an app that uses `fespalier_oidc` (since 0.21.0; they were in
/// `package:fespalier_auth/testing.dart`): a proof of possession with no crypto, a token
/// session for a widget test, and (since 0.27.0) a device sign-in the test drives by hand
/// (`FakeDeviceWait`, `FakeDeviceAuthorizationServer`).
///
/// For the core's fakes (`fakeAuth`, `FakeAuthBackend`), see `package:fespalier_auth/testing.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

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

/// The wait of a `DeviceSignIn` in a test (since 0.27.0): no timer, the test says when each wait
/// is over. Pass it as `DeviceSignIn(wait: fakeWait.call)`.
///
/// ```dart
/// final wait = FakeDeviceWait();
/// final signedIn = backend.signIn(DeviceSignIn(onCode: shown.add, wait: wait.call));
/// expect(await wait.next, const Duration(seconds: 5)); // the backend is waiting
/// server.approve();
/// wait.elapse(); // the backend polls, and signs in
/// final session = await signedIn;
/// ```
final class FakeDeviceWait {
  /// A wait; [onElapse] is told each interval that [elapse] ends (to move a fake clock on).
  FakeDeviceWait({this.onElapse});

  /// Called by [elapse] with the interval of the wait it ends.
  final void Function(Duration interval)? onElapse;

  /// Every interval asked for, oldest first.
  final List<Duration> intervals = [];

  final List<(Duration, Completer<void>)> _waiting = [];
  Completer<Duration>? _asked;

  /// Waits [interval], until the test calls [elapse].
  Future<void> call(Duration interval) {
    intervals.add(interval);
    final done = Completer<void>();
    _waiting.add((interval, done));
    final asked = _asked;
    _asked = null;
    asked?.complete(interval);
    return done.future;
  }

  /// Whether the backend is waiting.
  bool get isWaiting => _waiting.isNotEmpty;

  /// The interval of the oldest wait, once the backend waits (now when it already does).
  Future<Duration> get next {
    if (_waiting.isNotEmpty) return Future.value(_waiting.first.$1);
    return (_asked ??= Completer<Duration>()).future;
  }

  /// Ends the oldest wait, so the backend polls. A `StateError` when it is not waiting.
  void elapse() {
    if (_waiting.isEmpty) {
      throw StateError('FakeDeviceWait: the sign-in is not waiting');
    }
    final (interval, done) = _waiting.removeAt(0);
    onElapse?.call(interval);
    done.complete();
  }
}

/// A provider's device authorization endpoint and token endpoint in a test (since 0.27.0):
/// `FakeTransport(server.handle)` (`package:fespalier_transport/testing.dart`) answers with it.
/// The user's side is the test's: [approve], [deny], [expire], and [slowDownNext].
///
/// It answers RFC 8628's shapes: a code request (`device_code`, `user_code`,
/// `verification_uri`, `expires_in`, `interval`), then `authorization_pending` until the test
/// decides, and the tokens once (a second poll after them is `invalid_grant`). Any other request
/// is a 404.
final class FakeDeviceAuthorizationServer {
  /// A server at [deviceEndpoint] and [tokenEndpoint].
  FakeDeviceAuthorizationServer({
    required this.deviceEndpoint,
    required this.tokenEndpoint,
    this.userCode = 'WDJB-MJHT',
    Uri? verificationUri,
    this.verificationUriComplete,
    this.expiresIn = 600,
    this.interval = 5,
  }) : verificationUri =
           verificationUri ?? deviceEndpoint.replace(path: '/device');

  /// Where the code is asked for.
  final Uri deviceEndpoint;

  /// Where the backend polls.
  final Uri tokenEndpoint;

  /// The code the user is shown.
  final String userCode;

  /// The page the user is sent to.
  final Uri verificationUri;

  /// The page with the code in it; left out of the answer when null.
  final Uri? verificationUriComplete;

  /// `expires_in`, in seconds.
  final int expiresIn;

  /// `interval`, in seconds; left out of the answer when null.
  final int? interval;

  /// The forms of the code requests, oldest first.
  final List<Map<String, String>> codeRequests = [];

  /// The forms of the polls, oldest first.
  final List<Map<String, String>> polls = [];

  /// The headers of each poll, lower-case names (a `dpop` header when the backend proves).
  final List<Map<String, String>> pollHeaders = [];

  /// The `device_code` the server gave.
  String get deviceCode => 'fake-device-code';

  Map<String, Object?>? _tokens;
  String? _error;
  bool _slowDown = false;
  bool _consumed = false;

  /// The user approved: the next poll gets tokens. [claims] are the access token's (an
  /// unsigned JWT; `sub` by default), [tokenType] its `token_type` (`DPoP` for bound tokens),
  /// [extra] more fields of the answer (a `refresh_token`, an `id_token`).
  void approve({
    Map<String, Object?> claims = const {'sub': 'fake-user'},
    String tokenType = 'Bearer',
    int expiresIn = 300,
    Map<String, Object?> extra = const {},
  }) {
    _error = null;
    _tokens = {
      'access_token': _unsignedJwt(claims),
      'token_type': tokenType,
      'expires_in': expiresIn,
      ...extra,
    };
  }

  /// The user refused: the next poll is `access_denied`.
  void deny() => _error = 'access_denied';

  /// The code expired: the next poll is `expired_token`.
  void expire() => _error = 'expired_token';

  /// The next poll, if still pending, is `slow_down`.
  void slowDownNext() => _slowDown = true;

  /// Answers one request, as a transport's handler.
  FutureOr<TransportResponse> handle(TransportRequest request, Uint8List body) {
    final form = Uri.splitQueryString(utf8.decode(body, allowMalformed: true));
    String path(Uri uri) => '${uri.origin}${uri.path}';
    if (request.method == 'POST' && path(request.uri) == path(deviceEndpoint)) {
      codeRequests.add(form);
      return _json(200, {
        'device_code': deviceCode,
        'user_code': userCode,
        'verification_uri': verificationUri.toString(),
        'verification_uri_complete': ?verificationUriComplete?.toString(),
        'expires_in': expiresIn,
        'interval': ?interval,
      });
    }
    if (request.method == 'POST' && path(request.uri) == path(tokenEndpoint)) {
      polls.add(form);
      pollHeaders.add({
        for (final e in request.headers.entries) e.key.toLowerCase(): e.value,
      });
      if (form['device_code'] != deviceCode || _consumed) {
        return _json(400, {'error': 'invalid_grant'});
      }
      final error = _error;
      if (error != null) return _json(400, {'error': error});
      final tokens = _tokens;
      if (tokens != null) {
        _consumed = true;
        return _json(200, tokens);
      }
      if (_slowDown) {
        _slowDown = false;
        return _json(400, {'error': 'slow_down'});
      }
      return _json(400, {'error': 'authorization_pending'});
    }
    return _json(404, {'error': 'not_found'});
  }

  static TransportResponse _json(int status, Map<String, Object?> body) =>
      TransportResponse.fromBytes(
        statusCode: status,
        headers: const {'content-type': 'application/json'},
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
      );

  static String _unsignedJwt(Map<String, Object?> claims) {
    String part(Object json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    return '${part({'alg': 'none', 'typ': 'JWT'})}.${part(claims)}.';
  }
}
