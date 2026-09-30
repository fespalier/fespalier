import 'package:features/catalog.dart';
import 'package:fespalier/fespalier.dart';

/// Selects the app's own provider: the return type says so (no `Ref`), and names
/// the value (`Product`) the page is given. Nothing wraps `productProvider`, so its
/// retry policy is what runs, and the route's `refresh` re-runs it.
ProviderListenable<AsyncValue<Product>> data({required String productId}) =>
    productProvider(productId);
