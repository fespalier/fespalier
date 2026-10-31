import 'package:cratestack_example/app.g.dart';
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

/// Pays an order. Paying moves money, so the server needs a **user-presence** proof: `payOrder`
/// declares `@authn(amr: ["user"])` in the schema. The call is an ordinary one, signed by the
/// ambient key; the server answers it with a step-up refusal (RFC 9470), and the session signs it
/// again with the **user-present** key (behind a biometric or the device credential) and sends it
/// once more. Nothing here asks for the key: the rule is the server's, and the session follows it.
///
/// A cancelled prompt leaves the server's refusal as the answer: a `CratestackRpcException` whose
/// `stepUp` is set. It fails this one call; the session, the ambient key and every other request go
/// on working, and the page lets the user try again.
Future<Order> pay(Ref ref, {required int id, required Object? input}) => ref
    .read(ordersClientProceduresApiProvider)
    .payOrder(
      PayOrderProcedureArgs(args: PayOrderArgs(id: id)),
      options: CratestackRpcCallOptions(idempotencyKey: newIdempotencyKey()),
    );
