import 'package:flutter/material.dart';

/// A catch-all can be typed: `List<int> ids` reads every part as an int, so
/// `/compare/3/7/12` is `[3, 7, 12]` and `/compare/3/x` is not found. It can be a
/// `List` of `int`, `double`, `num`, `bool`, `DateTime` or `String` (the default).
class ComparePage extends StatelessWidget {
  const ComparePage({super.key, required this.ids, required this.total});

  final List<int> ids;
  final int total;

  @override
  Widget build(BuildContext context) =>
      Text('Compare ${ids.join(' vs ')} (total $total)');
}
