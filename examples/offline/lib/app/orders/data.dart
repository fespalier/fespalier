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
/// It reads again when the network is back (`reconnectSignal`: here the switch fires it, on a device
/// `fespalier_connectivity`'s `ConnectivitySignal` does). It watches the signal itself rather than
/// declare a `freshness`: a route with a `freshness` keeps its page when a reload fails
/// (`keepDataOnError`), which would leave an old copy on screen over a refusal.
FutureOr<Served<List<Order>>> data(Ref ref) {
  ref.watch(reconnectSignal);
  return ref.serve(
    key: 'orders',
    codec: _codec,
    empty: () =>
        const [], // nothing saved yet, offline, is an answer: Served.neverFetched
    maxAge: const Duration(hours: 1), // drives Served.stale
    fetch: () => ref.read(shopClient).orders(),
  );
}
