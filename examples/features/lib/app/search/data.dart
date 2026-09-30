import 'package:fespalier/fespalier.dart';

const _fruit = {
  'apple': ['red', 'sweet'],
  'apricot': ['orange', 'sweet'],
  'avocado': ['green'],
  'banana': ['yellow', 'sweet'],
  'blueberry': ['blue', 'sweet'],
  'cherry': ['red'],
};

/// How many times [data] ran; the tests read it to see that equal keys share a run.
int searchFetches = 0;

/// Optional nullable parameters are query parameters: `/search?q=ap&page=2`.
/// A `List` is one too (`?tags=red&tags=sweet`). The generated provider is
/// keyed by all of them; the list becomes a `QueryList` in the key, so equal
/// lists share one provider even when the page builds a new list each time.
Future<List<String>> data(
  Ref ref, {
  String? q,
  int? page,
  List<String> tags = const [],
}) async {
  searchFetches++;
  final hits = [
    for (final MapEntry(:key, :value) in _fruit.entries)
      if (key.contains(q ?? '') && tags.every(value.contains)) key,
  ];
  return hits.skip(((page ?? 1) - 1) * 2).take(2).toList();
}
