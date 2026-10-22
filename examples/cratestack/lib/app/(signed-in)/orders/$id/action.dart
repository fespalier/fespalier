import 'package:cratestack_example/app.g.dart';
import 'package:cratestack_example/src/confirm_transport.dart';
import 'package:cratestack_example/src/idempotency.dart';
import 'package:fespalier/fespalier.dart';
import 'package:orders_client/orders_client.dart'
    show
        CratestackRpcCallOptions,
        Order,
        PayOrderArgs,
        PayOrderProcedureArgs,
        ordersClientProceduresApiProvider;

/// The order on this page, and the list above it, are stale after a payment.
const invalidates = [OrderRoute, OrdersRoute];

/// Pays an order. Paying moves money, so the call asks for the **user-present** key: the signature
/// is made behind a biometric or the device credential, and the caption is the header's value
/// ([confirmHeader], which `ConfirmTransport` turns into the signer's attributes). The server
/// refuses a payment signed by the ambient key (`403 user_presence_required`).
///
/// A cancelled prompt is a `UserPresenceRefused`: it fails this one call. The session, the ambient
/// key and every other request go on working, and the page lets the user try again.
Future<Order> pay(Ref ref, {required int id, required Object? input}) => ref
    .read(ordersClientProceduresApiProvider)
    .payOrder(
      PayOrderProcedureArgs(args: PayOrderArgs(id: id)),
      options: CratestackRpcCallOptions(
        idempotencyKey: newIdempotencyKey(),
        headers: {confirmHeader: 'Confirm the payment of order $id'},
      ),
    );
