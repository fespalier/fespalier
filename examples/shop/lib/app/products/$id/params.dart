import 'package:trellis/trellis.dart';

/// Narrows `$id` from String to int. `/products/abc` → not_found.dart.
class ProductParams extends Params {
  const ProductParams({required this.id});

  final int id;
}
