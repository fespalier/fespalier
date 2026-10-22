import 'dart:convert';

import 'package:fespalier_transport/fespalier_transport.dart'
    show
        TransportAborted,
        TransportBroken,
        TransportPortal,
        TransportStatusError,
        TransportTimedOut,
        TransportUnsent,
        TransportUntrusted;

import 'errors.dart';

/// `fespalier_transport`'s failures to `CrateStackFailure` (since 0.21.0; it replaces
/// `DioFailures`): the last reader in `CrateStackErrors([readGenerated, TransportFailures.read])`.
///
/// What the generated client throws depends on its HTTP layer. A Dio client throws a
/// `DioException`, which `fespalier_dio`'s `DioErrors.toTransport` turns back into the failure
/// (or the `TransportStatusError`) that the transport chain produced:
///
/// ```dart
/// crateStackErrors.overrideWithValue(
///   CrateStackErrors([
///     readShopError,
///     (e) => TransportFailures.read(DioErrors.toTransport(e)),
///   ]),
/// )
/// ```
abstract final class TransportFailures {
  /// The failure [error] means, or null when it is not one this reader knows.
  ///
  /// A `TransportUnsent` or `TransportTimedOut` is [CrateStackOffline], and so is a
  /// `TransportPortal` (a gateway's or a captive portal's page, `PortalTransport`) and **every
  /// `5xx` without a CrateStack envelope** (`500` and `502` alike): the write may have landed, so
  /// an intent keeps its key. A `TransportAborted` is [CrateStackCancelled]. A
  /// `TransportBroken` and a `TransportUntrusted` (a certificate that does not verify may be a
  /// captive portal or an attack) are unknown, not offline: null. A `TransportStatusError` is classified by its status and body
  /// (`CrateStackFailure.fromResponse`), after the app's own reader had its turn: a body with a
  /// CrateStack envelope by its status and code, a `5xx` with an envelope is
  /// [CrateStackUnavailable].
  static CrateStackFailure? read(Object error) {
    switch (error) {
      case TransportAborted():
        return const CrateStackCancelled();
      case TransportUnsent() || TransportTimedOut() || TransportPortal():
        return CrateStackOffline(error);
      case TransportBroken() || TransportUntrusted():
        return null;
      case TransportStatusError():
        final type = error.headers['content-type'];
        return CrateStackFailure.fromResponse(
          status: error.statusCode,
          body: _json(type) ? _decode(error) : null,
          contentType: type,
          retryAfter: error.headers.containsKey('retry-after'),
          cause: error,
        );
      default:
        return null;
    }
  }

  static bool _json(String? type) =>
      type != null && type.toLowerCase().contains('json');

  static Object? _decode(TransportStatusError error) {
    if (error.body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(error.body));
    } on FormatException {
      return null;
    }
  }
}
