import 'package:cratestack_example/src/idempotency.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:orders_client/orders_client.dart'
    show
        CratestackRpcCallOptions,
        Order,
        PlaceOrderArgs,
        PlaceOrderProcedureArgs,
        ordersClientProceduresApiProvider;

/// What the form asks for.
typedef NewOrder = ({String item, int quantity});

/// Checked on the device before anything is sent; the server has the last word (see [action]).
FieldErrors? validate(NewOrder input) => input.item.trim().isEmpty
    ? FieldErrors({'item': 'Write what you want to order'})
    : null;

/// Places an order: a write through the generated client, with an `Idempotency-Key`.
///
/// - **The key** is minted here, once per call, and sent in the call's options: the session sends a
///   request again after renewing an expired attestation, with the same key, and the server runs the
///   write once ([newIdempotencyKey]).
/// - **A validation answer becomes `FieldErrors`.** `withCrateStackFieldErrors` reads the server's
///   `422` (`field 'quantity' must be between 1 and 99`) as `FieldErrors({'quantity': ...})` through
///   `crateStackErrors` (`readOrdersError`), so the form shows it under its field, and the order is
///   not kept anywhere.
/// - **The list is stale afterwards**, so the default `invalidates` (this route's `data.dart`) loads
///   it again.
Future<Order> action(Ref ref, {required NewOrder input}) => ref
    .read(ordersClientProceduresApiProvider)
    .placeOrder(
      PlaceOrderProcedureArgs(
        args: PlaceOrderArgs(item: input.item.trim(), quantity: input.quantity),
      ),
      options: CratestackRpcCallOptions(idempotencyKey: newIdempotencyKey()),
    )
    .withCrateStackFieldErrors(ref);
