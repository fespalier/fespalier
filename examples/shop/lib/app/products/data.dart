import 'package:fespalier/fespalier.dart';
import 'package:shop/api.dart';

/// data.dart can export its own provider. It's used as-is.
final data = FutureProvider.autoDispose<List<Product>>(
  (ref) => ref.watch(apiProvider).products(),
);
