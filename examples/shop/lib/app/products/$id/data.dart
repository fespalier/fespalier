import 'package:shop/api.dart';
import 'package:trellis/trellis.dart';

import 'params.dart';

Future<Product> data(Ref ref, ProductParams p) =>
    ref.watch(apiProvider).product(p.id);
