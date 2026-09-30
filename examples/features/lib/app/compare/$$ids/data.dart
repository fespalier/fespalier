import 'package:fespalier/fespalier.dart';

/// data.dart takes the typed list too: the provider is keyed by the path, and
/// `ids` arrives as a `List<int>` again.
Future<int> data(Ref ref, {required List<int> ids}) async =>
    ids.fold<int>(0, (sum, id) => sum + id);
