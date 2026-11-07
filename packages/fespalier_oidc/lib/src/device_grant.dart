import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'device_sign_in.dart';
import 'exception.dart';

/// The grant type of a device-code poll (RFC 8628 §3.4).
const deviceCodeGrantType = 'urn:ietf:params:oauth:grant-type:device_code';

/// What RFC 8628 adds to the poll interval after a `slow_down` (§3.5).
const slowDownStep = Duration(seconds: 5);

/// One answer of the provider: its status and body.
typedef DeviceAnswer = ({int status, String body});

/// Sends a form to a URL: [prove] adds the backend's DPoP proof, [abortTrigger] aborts the send.
typedef DevicePost =
    Future<DeviceAnswer> Function(
      Uri uri,
      Map<String, String> form, {
      required bool prove,
      Future<void>? abortTrigger,
    });

/// RFC 8628 from the client's side: asks [deviceEndpoint] for a code, shows it through
/// `request.onCode`, then polls [tokenEndpoint] until the user approved it, and returns the token
/// endpoint's 200 answer. Every wait is `request.wait`: no timer here.
Future<DeviceAnswer> runDeviceGrant({
  required DeviceSignIn request,
  required Uri deviceEndpoint,
  required Uri tokenEndpoint,
  required String clientId,
  required List<String> scopes,
  required DevicePost post,
}) async {
  final cancel = request.cancel;
  var cancelled = false;
  // A side `then`: it only sets a flag, which every step reads.
  if (cancel != null) {
    unawaited(
      cancel.then<void>(
        (_) => cancelled = true,
        onError: (Object _) => cancelled = true,
      ),
    );
  }

  Future<DeviceAnswer> send(Uri uri, Map<String, String> form, bool prove) =>
      post(
        uri,
        form,
        prove: prove,
        abortTrigger: cancel,
      ).onError<TransportAborted>((_, _) => throw const AuthCancelled());

  if (cancelled) throw const AuthCancelled();
  final start = await send(deviceEndpoint, {
    'client_id': clientId,
    if (scopes.isNotEmpty) 'scope': scopes.join(' '),
    ...request.parameters,
  }, false);
  if (cancelled) throw const AuthCancelled();
  final startJson = _json(start.body);
  if (start.status != 200) {
    throw _refusal(start, startJson, 'the device authorization endpoint');
  }
  final deviceCode = startJson['device_code'];
  final userCode = startJson['user_code'];
  // `verification_url` is the name of a draft of RFC 8628 that Google still answers with.
  final verification =
      startJson['verification_uri'] ?? startJson['verification_url'];
  final expiresIn = startJson['expires_in'];
  if (deviceCode is! String ||
      deviceCode.isEmpty ||
      userCode is! String ||
      userCode.isEmpty ||
      verification is! String ||
      expiresIn is! num) {
    throw const OidcException(
      'the device authorization endpoint answered without device_code, user_code, '
      'verification_uri or expires_in',
    );
  }
  final verificationUri = Uri.tryParse(verification);
  if (verificationUri == null) {
    throw const OidcException(
      'the device authorization endpoint answered a verification_uri that is not a URL',
    );
  }
  final complete = startJson['verification_uri_complete'];
  final given = startJson['interval'];
  var interval = given is num && given > 0
      ? Duration(milliseconds: (given * 1000).round())
      : slowDownStep;
  final expiresAt = clock.now().add(
    Duration(milliseconds: (expiresIn * 1000).round()),
  );
  await request.onCode(
    DeviceCode(
      userCode: userCode,
      verificationUri: verificationUri,
      verificationUriComplete: complete is String
          ? Uri.tryParse(complete)
          : null,
      expiresAt: expiresAt,
      interval: interval,
    ),
  );

  void checkStillOn() {
    if (cancelled) throw const AuthCancelled();
    if (!clock.now().isBefore(expiresAt)) {
      throw const AuthRejected(
        'expired_token',
        'the device code expired before the user approved it',
      );
    }
  }

  while (true) {
    checkStillOn();
    final waited = Future<void>.sync(() => request.wait(interval));
    await (cancel == null
        ? waited
        : Future.any<void>([waited, cancel.catchError((Object _) {})]));
    checkStillOn();
    final DeviceAnswer answer;
    try {
      answer = await send(tokenEndpoint, {
        'grant_type': deviceCodeGrantType,
        'device_code': deviceCode,
        'client_id': clientId,
      }, true);
    } on TransportFailure catch (failure) {
      // RFC 8628 §3.5: on a connection timeout, back off; a poll is a read, so it is safe to
      // send again. Anything else ends the sign-in.
      if (failure is TransportTimedOut || failure is TransportUnsent) {
        interval *= 2;
        continue;
      }
      rethrow;
    }
    if (answer.status == 200) return answer;
    final json = _json(answer.body);
    switch (json['error']) {
      case 'authorization_pending':
        continue;
      case 'slow_down':
        interval += slowDownStep;
        continue;
      default:
        throw _refusal(answer, json, 'the token endpoint');
    }
  }
}

Map<String, Object?> _json(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) return decoded;
  } on FormatException {
    // Not JSON: no fields.
  }
  return const <String, Object?>{};
}

/// An OAuth error is the provider's refusal (`access_denied`, `expired_token`, `invalid_client`,
/// ...): `AuthRejected`. A 5xx or an answer with no error is an `OidcException`.
Exception _refusal(DeviceAnswer answer, Map<String, Object?> json, String who) {
  final error = json['error'];
  final description = json['error_description'] is String
      ? json['error_description'] as String
      : null;
  if (error is String && answer.status >= 400 && answer.status < 500) {
    return AuthRejected(error, description);
  }
  return OidcException(
    '$who answered HTTP ${answer.status}: '
    '${error is String ? error : 'no OAuth error in the answer'}'
    '${description == null ? '' : ': $description'}',
  );
}
