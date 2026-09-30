import 'package:features/catalog.dart';
import 'package:fespalier/fespalier.dart';

/// A segment and a query parameter: the family is keyed by a record of both.
ProviderListenable<AsyncValue<List<String>>> data({
  required String productId,
  int? page,
}) => reviewsProvider((productId: productId, page: page));
