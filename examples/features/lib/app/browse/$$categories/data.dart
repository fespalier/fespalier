import 'package:features/models/category.dart';
import 'package:fespalier/fespalier.dart';

/// A `List<Category>` catch-all keys data like any other: by its path, and `categories`
/// arrives as a `List<Category>` again.
Future<int> data(Ref ref, {required List<Category> categories}) async =>
    categories.toSet().length;
