import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';

/// A selector: the catalog provider already exists (`ready()` loads it), so data.dart returns it
/// instead of fetching again. This replaces the `ref.watch(catalogProvider)` the old page did.
ProviderListenable<AsyncValue<List<Product>>> data() => catalogProvider;
