import 'package:fespalier/fespalier.dart';
import 'package:live/orders.dart';

/// The order, live: a selector over its feed (`orderLive(id)`), which holds one event stream per order
/// watched. The page gets each event's order; a refusal (an order the server does not know) is
/// error.dart's.
ProviderListenable<AsyncValue<OrderUpdate>> data({required int id}) =>
    orderLive(id);
