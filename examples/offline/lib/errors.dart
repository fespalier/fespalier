import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/demo/demo_server.dart';
import 'package:offline/network.dart';

/// The error reader: what this app's transport throws becomes a classification.
///
/// A real app reads its generated client's exception here (and `DioFailures.read` for what Dio throws);
/// `fromEnvelope` applies the status and code table. An error no reader knows is `null`: a read rethrows
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

/// The readers `crateStackErrors` is overridden with.
const shopErrors = CrateStackErrors([readShopError]);
