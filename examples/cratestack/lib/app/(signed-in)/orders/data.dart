import 'dart:async';

import 'package:cratestack_example/src/orders.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:orders_client/orders_client.dart'
    show
        ListOrdersArgs,
        ListOrdersProcedureArgs,
        Order,
        ordersClientProceduresApiProvider;

/// The signed-in user's orders, through the generated client.
///
/// - `ref.cancellable` runs the call in a zone that carries this provider's abort trigger, which the
///   generated transport merges into the request's `abortTrigger`: leaving the page aborts the load,
///   and the aborted request fails with a `TransportAborted` (`CrateStackCancelled`), not an error
///   page. `ref.watch` the client **before** it: a provider built inside the body would run in the same
///   zone and take the trigger with it.
/// - `ref.serve` is the offline half: on an answer the list is saved on the device with the time the
///   server gave it, and when the server cannot be reached (`CrateStackOffline`: no network, a
///   captive portal's page) the page gets that copy, marked `ServedFrom.local`. A refusal, a `401`
///   included, is the answer: it is never covered by the copy.
FutureOr<Served<List<Order>>> data(Ref ref) {
  final api = ref.watch(ordersClientProceduresApiProvider);
  return ref.serve<List<Order>>(
    key: 'orders',
    codec: ordersCodec,
    empty: () =>
        const [], // nothing saved yet, offline, is an answer: Served.neverFetched
    maxAge: const Duration(hours: 1), // drives Served.stale
    fetch: () => ref.cancellable(() async {
      final list = await api.listOrders(
        ListOrdersProcedureArgs(args: ListOrdersArgs()),
      );
      return list.orders.toList();
    }),
  );
}
