import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/demo/demo_server.dart';
import 'package:offline/network.dart';

/// The app's own error reader: what the demo server throws becomes a classification.
///
/// A real app reads its generated client's exception here; `fromEnvelope` applies the status and code
/// table. An error no reader knows is `null`: the next reader gets it, and when none does a read rethrows
/// it and a `submit` keeps the intent queued, because the call may have landed.
CrateStackFailure? readShopError(Object error) => switch (error) {
  Unreachable() => CrateStackOffline(error),
  DemoError(:final status, :final code, :final message) =>
    CrateStackFailure.fromEnvelope(
      status: status,
      code: code,
      message: message,
    ),
  _ => null,
};

/// The readers `crateStackErrors` is overridden with: the app's own, then `TransportFailures.read`, which
/// classifies what a transport chain fails with (`TransportUnsent` and `TransportTimedOut` are offline,
/// `TransportAborted` is a cancelled read). This demo has no Dio; a generated Dio client's reader is
/// `(e) => TransportFailures.read(DioErrors.toTransport(e))` (`fespalier_dio`).
const shopErrors = CrateStackErrors([readShopError, TransportFailures.read]);
