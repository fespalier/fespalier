import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/shop.dart';

final _codec = ServedCodec<List<Order>>(
  toJson: (orders) => [for (final order in orders) order.toMap()],
  fromJson: (json) => [
    for (final map in json! as List<Object?>)
      Order.fromMap(map! as Map<String, Object?>),
  ],
);

/// The server's orders. The policy is `networkFirst` (the default): the server, then the copy this
/// account last loaded here on a connection failure. `Served` says which one it is, and as of when.
/// A refusal (a 403) is never answered from the copy: it goes to error.dart.
///
/// It reads again when the network is back (`refetchOnReconnect`; `reconnectSignal` fires here when
/// the switch is turned on, on a device `fespalier_connectivity`'s `ConnectivitySignal` does). A route
/// with a `freshness` keeps its page when a reload fails offline, but not for a refusal (a 403 is a
/// `DataRefusal`, since 0.13.1): error.dart shows instead of the page.
const freshness = Freshness(refetchOnReconnect: true);

FutureOr<Served<List<Order>>> data(Ref ref) {
  return ref.serve(
    key: 'orders',
    codec: _codec,
    empty: () =>
        const [], // nothing saved yet, offline, is an answer: Served.neverFetched
    maxAge: const Duration(hours: 1), // drives Served.stale
    fetch: () => ref.read(shopClient).orders(),
  );
}
