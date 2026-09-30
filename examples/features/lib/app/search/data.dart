import 'package:fespalier/fespalier.dart';

const _fruit = ['apple', 'apricot', 'avocado', 'banana', 'blueberry', 'cherry'];

/// Optional nullable parameters are query parameters: `/search?q=ap&page=2`.
/// The generated provider is keyed by both.
Future<List<String>> data(Ref ref, {String? q, int? page}) async {
  final hits = _fruit.where((f) => f.contains(q ?? '')).toList();
  return hits.skip(((page ?? 1) - 1) * 2).take(2).toList();
}
