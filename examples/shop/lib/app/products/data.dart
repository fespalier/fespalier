import 'package:shop/api.dart';
import 'package:trellis/trellis.dart';

Future<List<Product>> data(Ref ref, Params params) =>
    ref.watch(apiProvider).products();
