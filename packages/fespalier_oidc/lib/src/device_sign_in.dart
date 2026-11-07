import 'dart:async';

import 'package:fespalier_auth/fespalier_auth.dart';

/// Waits [interval] before the next poll of a device sign-in (since 0.27.0).
///
/// The package starts no timer, so the wait is the app's: `(interval) => Future.delayed(interval)`
/// in the app, a `FakeDeviceWait` (`package:fespalier_oidc/testing.dart`) in a test, which the test
/// completes by hand. The future may complete early (a "check now" button) or late: the backend
/// polls when it completes, and answers a `slow_down` by asking for a longer wait.
typedef DeviceWait = Future<void> Function(Duration interval);

/// What the user is shown during a device sign-in (since 0.27.0): the code to type, and where.
///
/// It holds no secret: the `device_code` the backend polls with stays in the backend.
final class DeviceCode {
  /// The code [userCode] to enter at [verificationUri].
  const DeviceCode({
    required this.userCode,
    required this.verificationUri,
    this.verificationUriComplete,
    required this.expiresAt,
    required this.interval,
  });

  /// The code the user types on the other device (`user_code`), e.g. `WDJB-MJHT`.
  final String userCode;

  /// Where the user types it (`verification_uri`): show it as text, short enough to type.
  final Uri verificationUri;

  /// The same page with the code in it (`verification_uri_complete`), when the provider gives
  /// one: the URL for a QR code. Not every provider does (`authkestra-op` does not).
  final Uri? verificationUriComplete;

  /// When the codes stop working (`expires_in` after the request), by `clock.now()`.
  final DateTime expiresAt;

  /// How long the backend waits between two polls at first (`interval`, 5 seconds when the
  /// provider does not say).
  final Duration interval;

  @override
  String toString() =>
      'DeviceCode($userCode at $verificationUri, until $expiresAt)';
}

/// Sign in on another device: the OAuth 2.0 device authorization grant (RFC 8628), for a TV, a
/// kiosk or a CLI with no browser or keyboard (since 0.27.0).
///
/// `OidcBackend.signIn` asks the provider's device authorization endpoint for a code, hands it
/// to [onCode] (the page shows it), then polls the token endpoint, waiting [wait] between two
/// polls, until the user approved it on their phone. The session then holds a
/// `TokenCredential`, DPoP-bound when the backend has a proof.
///
/// ```dart
/// await ref.read(authSession.notifier).signIn(
///   DeviceSignIn(
///     onCode: (code) => ref.read(shownCode.notifier).show(code),
///     wait: (interval) => Future.delayed(interval),
///     cancel: cancelled.future, // a "Cancel" button completes it
///   ),
/// );
/// ```
///
/// It throws `AuthCancelled` when [cancel] completes (a request in flight is aborted too),
/// `AuthRejected('access_denied')` when the user refused, `AuthRejected('expired_token')` when
/// the code expired first, `AuthRejected(<error>)` for any other refusal of the provider, and an
/// `OidcException` for an answer it cannot read.
final class DeviceSignIn extends SignInRequest {
  /// A device sign-in that shows its code through [onCode] and waits with [wait].
  const DeviceSignIn({
    required this.onCode,
    required this.wait,
    this.cancel,
    this.scopes,
    this.parameters = const {},
  });

  /// Called once with the code to show, before the first poll. The polls start when it
  /// returns (a future it returns is awaited).
  final FutureOr<void> Function(DeviceCode code) onCode;

  /// Waits between two polls: the app's timer, since the package has none.
  final DeviceWait wait;

  /// Completes to cancel the sign-in: the wait is left, a request in flight is aborted, and
  /// `signIn` throws `AuthCancelled`.
  final Future<void>? cancel;

  /// The scopes asked for; null for the backend's `scopes`. Add `offline_access` for a refresh
  /// token on a provider that only gives one then (`authkestra-op` does).
  final List<String>? scopes;

  /// Extra fields of the device authorization request (e.g. `{'audience': '...'}`).
  final Map<String, String> parameters;
}
