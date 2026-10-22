import 'dart:async';

import 'package:fespalier/fespalier.dart' show Ref;
import 'package:fespalier_transport/fespalier_transport.dart'
    show TransportZone;

/// Cancelling a read's requests with its provider, through a generated client (since 0.10.0).
extension CrateStackCancelRef on Ref {
  /// Runs [body] with this provider's abort trigger in the zone (`TransportZone`), so every
  /// request [body] makes through a client whose adapter reads it (`fespalier_dio`'s
  /// `TransportAdapter`) is aborted when the provider is disposed or rebuilt: it fails with
  /// `TransportAborted`, which `TransportFailures.read` reads as `CrateStackCancelled`.
  ///
  /// The generated options carry no cancel token, which is why the trigger travels in a zone
  /// value. The body must be only the client call: read or watch other providers **before**
  /// `cancellable`, not inside it. A provider built inside the body runs in the same zone, so its
  /// own requests would take this provider's trigger and be aborted with it.
  ///
  /// Call it before the first `await` of the provider. Returns [body]'s very `Future`, and starts
  /// no timer.
  Future<T> cancellable<T>(Future<T> Function() body) {
    // `onDispose` on a Ref that is gone throws: the answer is a trigger that has already fired.
    if (!mounted) return TransportZone.run(Future<void>.value(), body);
    final trigger = Completer<void>();
    onDispose(trigger.complete);
    return TransportZone.run(trigger.future, body);
  }
}
