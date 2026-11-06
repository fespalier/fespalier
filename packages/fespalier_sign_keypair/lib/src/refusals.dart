import 'dart:convert';

/// What a client does with a refusal of Authkestra's device-signature profile v1 (RFC-014 §5,
/// since the release after 0.25.0).
enum DeviceRefusalAction {
  /// The refusal stands: no renewal, no sign-out, no loop.
  none,

  /// Renew the attestation of the key that signed, then send again, once.
  renew,

  /// The key is not the one enrolled: sign out as `keyLost`.
  keyLost,

  /// The device was revoked: sign out as `revoked`, and wipe.
  revoked,

  /// Sign this request again with the user-present key, once.
  stepUp,
}

/// The refusals of Authkestra's device-signature profile v1 (RFC-014 §5), as a server sends them
/// and a client reads them (since the release after 0.25.0).
///
/// A refusal is the status of [statuses], `content-type: application/json`, the body exactly
/// `{"error":"<code>"}` ([body]) and, for a `401`, `www-authenticate: DeviceSignature
/// error="<code>"` ([challenge]); [headers] is both headers. The verifier's own codes are
/// `DeviceSignatureError`'s; the three below are the adapter's and the application's.
abstract final class DeviceRefusals {
  /// `413`: the body is over the server's limit (an adapter's refusal).
  static const String bodyTooLarge = 'body_too_large';

  /// `403`: the application revoked the device. The client signs out as `revoked`.
  static const String deviceRevoked = 'device_revoked';

  /// `401`: the route needs the user-present key (the application's step-up). The client signs
  /// the request again with it, once.
  static const String insufficientUserAuthentication =
      'insufficient_user_authentication';

  /// The status of every code of the profile.
  static const Map<String, int> statuses = {
    'missing_credential': 401,
    'malformed': 401,
    'bad_alg': 401,
    'untrusted_issuer': 401,
    'unknown_kid': 401,
    'bad_attestation': 401,
    'attestation_expired': 401,
    'device_not_active': 401,
    'bad_jwk': 401,
    'key_not_bound': 401,
    'bad_signature': 401,
    'signature_expired': 401,
    'lifetime_too_long': 401,
    'method_mismatch': 401,
    'path_mismatch': 401,
    'audience_mismatch': 401,
    'query_mismatch': 401,
    'body_mismatch': 401,
    'replay_detected': 401,
    bodyTooLarge: 413,
    deviceRevoked: 403,
    insufficientUserAuthentication: 401,
  };

  /// What a client does for each code the profile gives an action other than
  /// [DeviceRefusalAction.none].
  static const Map<String, DeviceRefusalAction> actions = {
    'missing_credential': DeviceRefusalAction.keyLost,
    'unknown_kid': DeviceRefusalAction.renew,
    'attestation_expired': DeviceRefusalAction.renew,
    'device_not_active': DeviceRefusalAction.renew,
    'bad_jwk': DeviceRefusalAction.keyLost,
    'key_not_bound': DeviceRefusalAction.keyLost,
    deviceRevoked: DeviceRefusalAction.revoked,
    insufficientUserAuthentication: DeviceRefusalAction.stepUp,
  };

  /// The names clients shipped before v1, by the v1 code they stand for (`mismatch` stands for
  /// any `*_mismatch`, which all mean the same to a client: none). Read lower-cased, so
  /// `DEVICE_REVOKED`, Webank's, is `device_revoked`.
  static const Map<String, String> legacyAliases = {
    'replay': 'replay_detected',
    'mismatch': 'method_mismatch',
    'device_revoked': deviceRevoked,
  };

  /// The v1 code [error] stands for: itself, lower-cased, or what a legacy name meant.
  static String canonical(String error) {
    final lower = error.toLowerCase();
    return legacyAliases[lower] ?? lower;
  }

  /// What a client does for a refusal with [statusCode] and [error] (a v1 code or a legacy
  /// name): the profile's action when the status is the code's, else none. A code that is not
  /// the profile's is none: it is ambiguous, so the session is never wiped and a request never
  /// loops on it.
  static DeviceRefusalAction actionOf(int statusCode, String error) {
    final code = canonical(error);
    if (statuses[code] != statusCode) return DeviceRefusalAction.none;
    return actions[code] ?? DeviceRefusalAction.none;
  }

  /// The body of a refusal: exactly `{"error":"<code>"}`.
  static String body(String code) => jsonEncode({'error': code});

  /// The `www-authenticate` challenge of a `401`: `DeviceSignature error="<code>"`.
  static String challenge(String code) => 'DeviceSignature error="$code"';

  /// The headers of a refusal: the JSON content type and, for a `401`, the challenge.
  static Map<String, String> headers(String code, {required int statusCode}) =>
      {
        'content-type': 'application/json',
        if (statusCode == 401) 'www-authenticate': challenge(code),
      };
}
