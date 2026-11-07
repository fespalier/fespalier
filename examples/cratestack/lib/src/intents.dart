import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:orders_client/orders_client.dart'
    show CratestackRpcAdapter, CratestackRpcCallOptions;

/// The seam `fespalier_cratestack`'s intent queue sends through: the generated RPC adapter, so a
/// queued call goes out on the app's session (`authTransport`) like any other generated call.
///
/// The queue stores a call once (its op and its wire input) and sends those bytes on every attempt,
/// under the same `Idempotency-Key`; **the session signs each attempt when it is sent**, with a fresh
/// `jti`, never when it was queued. So an intent that waited offline through a renewal, or a
/// revocation, goes out with the credential of the moment it is sent, and a revoked device's intent
/// is refused (`403 device_revoked`) rather than replayed.
final class OrdersIntentTransport implements CrateStackTransport {
  /// The transport over [adapter] (`ordersClientAdapterProvider`).
  const OrdersIntentTransport(this.adapter);

  /// The generated adapter.
  final CratestackRpcAdapter adapter;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) =>
      switch (call) {
        RpcCall(:final opId, :final input) => adapter.call(
          opId,
          input,
          options: CratestackRpcCallOptions(idempotencyKey: idempotencyKey),
        ),
        RestCall() => throw UnsupportedError(
          'this server speaks CrateStack RPC only',
        ),
      };
}
