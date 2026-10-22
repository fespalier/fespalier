import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:orders_client/orders_client.dart'
    show CratestackRpcException, CratestackTransportException;

/// What the generated client throws, as a classification `fespalier_cratestack` understands.
///
/// - A `CratestackRpcException` is the server's answer: `fromEnvelope` applies the status and code
///   table (a `401` is `CrateStackUnauthenticated`, a `5xx` in CrateStack's envelope is
///   `CrateStackUnavailable`, any other `4xx` is `CrateStackRefused`).
/// - A `CratestackTransportException` is no answer at all. The generated transport wraps fespalier's
///   `TransportFailure` in it as its `cause`, so this reader hands the cause on to
///   `TransportFailures.read`: `TransportUnsent`, `TransportTimedOut` and a captive portal's page are
///   `CrateStackOffline`, an abort is `CrateStackCancelled`, and a refused certificate is unknown
///   (null), never "offline".
///
/// A rejected field arrives as `422 invalid_argument` (CrateStack's RPC codes are gRPC-style), which
/// `fieldErrorsOf` and `withCrateStackFieldErrors` read like REST's `VALIDATION_ERROR` since 0.21.0.
CrateStackFailure? readOrdersError(Object error) => switch (error) {
  CratestackRpcException(
    :final status,
    :final code,
    :final message,
    :final details,
  ) =>
    CrateStackFailure.fromEnvelope(
      status: status,
      code: code,
      message: message,
      details: details,
    ),
  CratestackTransportException(:final cause?) => TransportFailures.read(cause),
  _ => null,
};

/// The readers `crateStackErrors` is overridden with: this app's, then the transport's own, for a
/// failure that arrives unwrapped.
const ordersErrors = CrateStackErrors([
  readOrdersError,
  TransportFailures.read,
]);
