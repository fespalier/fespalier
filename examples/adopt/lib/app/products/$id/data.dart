import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';

ProviderListenable<AsyncValue<Product>> data({required int id}) =>
    productProvider(id);
