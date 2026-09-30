import 'package:fespalier/fespalier.dart';
import 'package:shop/api.dart';

/// Asking for `int id` makes `$id` an int everywhere: `ProductRoute(id: 42)`,
/// and `/products/abc` goes to not_found.dart.
Future<Product> data(Ref ref, {required int id}) =>
    ref.watch(apiProvider).product(id);
