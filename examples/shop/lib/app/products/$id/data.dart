import 'package:fespalier/fespalier.dart';
import 'package:shop/api.dart';

/// A product is fresh for a minute: opening it again within that minute does not load it again,
/// and after it the old product shows at once while the new one loads. Coming back to the app
/// (the foreground) loads it again too, once it is a minute old.
const freshness = Freshness(
  staleTime: Duration(minutes: 1),
  refetchOnResume: true,
);

/// The last product of each id is saved for the next start: it shows while the network
/// answers, and when the network does not (offline), error.dart is left out. Nothing is saved
/// until main.dart gives a `dataCacheStorage`.
final dataCache = DataCache<Product>.json(
  toJson: (p) => p.toJson(),
  fromJson: (j) => Product.fromJson(j! as Map<String, Object?>),
);

/// Asking for `int id` makes `$id` an int everywhere: `ProductRoute(id: 42)`,
/// and `/products/abc` goes to not_found.dart.
Future<Product> data(Ref ref, {required int id}) =>
    ref.watch(apiProvider).product(id);
