import 'package:fespalier/fespalier.dart';
import 'package:minimal/items.dart';

/// data.dart beside a page.dart loads what the page shows. The page is only
/// built once this has finished: loading.dart shows meanwhile, and error.dart
/// if it throws.
///
/// `required int id` also makes `$id` an int everywhere: ItemRoute(id: 1), and
/// `/items/abc` goes to not_found.dart instead of reaching this function.
Future<Item> data(Ref ref, {required int id}) => fetchItem(id);
