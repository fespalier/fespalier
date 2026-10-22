import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:orders_client/orders_client.dart'
    show
        GetOrderArgs,
        GetOrderProcedureArgs,
        Order,
        ordersClientProceduresApiProvider;

/// One order, through the generated client, in `ref.cancellable`: leaving the page aborts the load.
/// A `404` is the server's answer, shown by error.dart's default.
Future<Order> data(Ref ref, {required int id}) {
  final api = ref.watch(ordersClientProceduresApiProvider);
  return ref.cancellable(
    () => api.getOrder(GetOrderProcedureArgs(args: GetOrderArgs(id: id))),
  );
}
